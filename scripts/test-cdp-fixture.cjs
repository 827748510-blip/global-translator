#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const http = require('node:http');
const { chromium } = require(process.env.GT_PLAYWRIGHT_MODULE || 'playwright');
(async () => {
 const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'gt-cdp-fixture-'));
 let browser, page;
 const fixtures = { ja:['ja','切手','大丈夫'], ko:['ko','大丈夫'], zh:['zh-Hans','普通中文'], traditional:['zh-TW','歡迎使用'], missing:['','普通中文'], invalid:['java','普通中文'] };
 const server = http.createServer(async (req,res) => {
  try {
   const url = new URL(req.url,'http://127.0.0.1');
   if (url.pathname === '/state') {
    res.setHeader('Content-Type','application/json');
    res.end(JSON.stringify(await page.locator('p').allTextContents()));return;
   }
   if (url.pathname === '/navigate') {
    await page.goto('http://127.0.0.1:'+server.address().port+'/page?case='+url.searchParams.get('case'));
    await page.bringToFront();res.end('ok');return;
   }
   const fixture=fixtures[url.searchParams.get('case')] || fixtures.ja;
   res.setHeader('Content-Type','text/html; charset=utf-8');
   res.end('<!doctype html><html lang="'+fixture[0]+'"><body>'+fixture.slice(1).map(text=>'<p>'+text+'</p>').join('')+'</body></html>');
  } catch (e) {res.statusCode=500;res.end(String(e));}
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 browser=await chromium.launchPersistentContext(path.join(temporary,'profile'),{executablePath:process.env.GT_CHROMIUM_PATH,headless:true,args:['--remote-debugging-port=0']});
 page=browser.pages()[0] || await browser.newPage();
 await page.goto('http://127.0.0.1:'+server.address().port+'/page?case=ja');
 await page.bringToFront();
 const portFile=path.join(temporary,'profile','DevToolsActivePort');
 for(let i=0;i<100&&!fs.existsSync(portFile);i++) await new Promise(r=>setTimeout(r,20));
 const cdpPort=Number(fs.readFileSync(portFile,'utf8').split('\n')[0]);
 fs.writeFileSync(process.argv[2],JSON.stringify({cdpPort,fixturePort:server.address().port}));
 let closing=false;
 async function close(){if(closing)return;closing=true;await browser.close();await new Promise(r=>server.close(r));fs.rmSync(temporary,{recursive:true,force:true});process.exit(0);}
 process.on('SIGTERM',close);
 process.on('SIGINT',close);
})().catch(e=>{console.error(e);process.exitCode=1;});
