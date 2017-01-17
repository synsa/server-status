--[[
Licensed to the Apache Software Foundation (ASF) under one
or more contributor license agreements.  See the NOTICE file
distributed with this work for additional information
regarding copyright ownership.  The ASF licenses this file
to you under the Apache License, Version 2.0 (the
"License"); you may not use this file except in compliance
with the License.  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing,
software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied.  See the License for the
specific language governing permissions and limitations
under the License.
]]

--[[ mod_lua implementation of the server-status page ]]

-- pre-declare some variables defined at the bottom of this script:
local status_js, status_css, quokka_js

-- quick and dirty JSON conversion
local function quickJSON(input)
    if type(input) == "table" then
        local t = 'array'
        for k, v in pairs(input) do
            if type(k) ~= "number" then
                t = 'hash'
            end
        end
        
        if t == 'hash' then
            local out = ""
            local tbl = {}
            for k, v in pairs(input) do
                local kv = ([["%s": %s]]):format(k, quickJSON(v))
                table.insert(tbl, kv)
            end
            return "{" .. table.concat(tbl, ", ") .. "}"
        else
            local tbl = {}
            for k, v in pairs(input) do
                table.insert(tbl, quickJSON(v))
            end
            return "[" .. table.concat(tbl, ", ") .. "]"
        end
    elseif type(input) == "string" then
        return ([["%s"]]):format(input:gsub('"', '\\"'):gsub("[\r\n\t]", " "))
    elseif type(input) == "number" then
        return tostring(input)
    elseif type(input) == "boolean" then
        return (input and "true" or "false")
    else
        return "null"
    end
end

-- Module information callback
local function modInfo(r, modname)
    if modname then
            r:puts [[
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8">
        <style>
        ]]
        r:puts (status_css)
        r:puts [[
        </style>
        <title>Module information</title>
      </head>
    
      <body>
    ]]
        r:puts( ("<h3>Details for module %s</h3>\n"):format(r:escape_html(modname)) )
        -- Queries the server for information about a module
        local mod = r.module_info(modname)
        if mod then
            for k, v in pairs(mod.commands) do
                -- print out all directives accepted by this module
                r:puts( ("<b>%s:</b> %s<br>\n"):format(r:escape_html(k), v))
            end
        end
        -- HTML tail
        r:puts[[
      </body>
    </html>
    ]]
    end
return apache2.OK;
end



-- Handler function
function handle(r)
    
    -- Parse GET data, if any, and set content type
    local GET = r:parseargs()

    -- Fetch server data
    local mpm = "prefork" -- assume prefork by default
    if r.mpm_query(14) == 1 then
        mpm = "event" -- this is event mpm
    elseif r.mpm_query(3) >= 1 then
        mpm = "worker" -- it's not event, but it's threaded, we'll assume worker mpm
    elseif r.mpm_query(2) == 1 then
        mpm = "winnt" -- it's threaded, but not worker nor event, so it's probably winnt
    end
    local maxServers = r.mpm_query(12);
    local maxThreads = r.mpm_query(6);
    local curServers = 0;
    local uptime = os.time() - r.started;
    local costs = {}
    local stime = 0;
    local utime = 0;
    local cons = 0;
    local bytes = 0;
    local threadActions = {}

    -- Fetch process/thread data
    for i=0,maxServers,1 do
        local server = r.scoreboard_process(r, i);
        if server then
            if server.pid > 0 then
                curServers = curServers + 1
                for j = 0, maxThreads-1, 1 do
                    local worker = r.scoreboard_worker(r, i, j)
                    if worker then
                        stime = stime + (worker.stimes or 0);
                        utime = utime + (worker.utimes or 0);
                        table.insert(costs, {
                            process = i,
                            thread = worker.tid,
                            cost = ((worker.utimes or 0) + (worker.stimes or 0)),
                            count = worker.access_count,
                            vhost = worker.vhost:gsub(":%d+", ""),
                            request = worker.request
                        })
                        threadActions[worker.status] = (threadActions[worker.status] or 0) + 1
                        cons = cons + worker.access_count;
                        bytes = bytes + worker.bytes_served;
                    end
                end
            end
        end
    end

    -- Try to calculate the CPU max
    local maxCPU = 5000000
    while (maxCPU < (stime+utime)) do
        maxCPU = maxCPU * 2
    end

    -- If we only need the stats feed, compact it and hand it over
    if GET['view'] and GET['view'] == "json_status" then
        --threadsKeepalive,threadsClosing,threadsIdle,threadsWriting,threadsReading,threadsGraceful
        local tbl ={
            states = {
                keepalive = threadActions[5] or 0,
                closing = threadActions[8] or 0,
                idle = threadActions[2] or 0,
                writing = threadActions[4] or 0,
                reading = threadActions[3] or 0,
                graceful = threadActions[9] or 0
            },
            uptime = uptime,
            connections = cons,
            bytes = bytes,
            servers = curServers,
            maxServers = maxServers,
            threads = maxThreads,
            systime = stime,
            utime = utime,
            costs = costs
        }
        r.content_type = "application/json"
        r:puts(quickJSON(tbl))
        return apache2.OK
    end

    
    -- Print out the HTML for the front page
    r.content_type = "text/html"
    r:puts ( ([=[
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <style>
    %s
    </style>
    <!--Load the AJAX API-->
    <script type="text/javascript">
    %s
    </script>
    <script type="text/javascript">
        %s
    </script>
    <title>Server status for %s</title>
  </head>

  <body onload="refreshCharts(false);">
    <h2>Status for %s on %s</h2>
    <div style="width: 90%%; float: left; clear: both; margin-bottom: 25px;">
    <b>Server version:</b> %s<br/>
    <b>Server Built:</b> %s<br/>
    <b>Server (re)started:</b> %s<br/>
    <b>Uptime: </b> <span id='uptime'></span><br/>
    <b>Server MPM:</b> %s<br/>
    <b>Generation:</b> %u<br/>
    <b>Current work-force:</b> <span id="current_threads">%u (%u processes x %u threads)</span><br/>
    <b>Maximum work-force:</b> <span id="max_threads">%u (%u processes x %u threads)</span><br/>
    <b>Connections accepted:</b> <span id="connections">%u (%.3f/sec)</span><br/>
    <b>Bytes transfered:</b> <span id="transfer"> %.2fMB (%.2fkB/sec, %.2fkB/req)</span><br/>
    </div>
    
    <!--Div that will hold the pie chart-->
    <canvas id="actions_div" width="1200" height="500" style="width: 600px; height: 250px; float: left;"></canvas>
    <canvas id="traffic_div" width="1200" height="500" style="width: 600px; height: 250px; float: left;"></canvas>
    <div style="clear: both"></div>
    <canvas id="status_div" width="800" height="500" style="width: 400px; height: 250px; float: left;"></canvas>
    <canvas id="cpu_div" width="800" height="500" style="width: 400px; height: 250px; float: left;"></canvas>
    <div id="costs_div" style="float: left; width:800px;"></div>

    <div style="clear: both;">
        <a id="show_link" href="javascript:void(0);" onclick="javascript:showDetails();">Show thread information</a><br>
        <a id="show_modules_link" href="javascript:void(0);" onclick="javascript:show_modules();">Show loaded modules</a>
    </div>


]=]):format(
    status_css,
    quokka_js,
    status_js:format(   curServers, maxServers, maxThreads, threadActions[2] or 0, threadActions[4] or 0,
                        threadActions[3] or 0 , threadActions[5] or 0 ,threadActions[8] or 0 ,
                        threadActions[9] or 0 , maxCPU - utime - stime, stime, utime, cons, uptime, bytes
                    ),
    
    r.server_name, r.banner, r.server_name, r.banner, r.server_built, os.date("%c",r.started), mpm, r.mpm_query(15),
    curServers*maxThreads,curServers,maxThreads,maxServers*maxThreads, maxServers,maxThreads,cons,
    cons/uptime, bytes/1024/1024, bytes/uptime/1024, bytes/cons/1024
    ) );

    r:flush()

    -- Print out details about each process/thread
    for i=0,curServers-1,1 do
        local info = r.scoreboard_process(r, i);
        if info.pid ~= 0 then
            r:puts("<div id='srv_",i+1,"' style='display: none; clear: both;' class='servers'><b>Server #", i+1, ":</b><br/>\n");
            for k, v in pairs(info) do
                r:puts(k, " = ", v, "<br/>\n");
            end
            r:puts([[<table id="server_]]..i..[[" name="server_]]..i..[[" border='1' style='font-family: arial, helvetica, sans-serif; font-size: 12px; border: 1px solid #666;'><tr>]])
            local worker = r.scoreboard_worker(r, i, 0);
            local p = 0;
            for k, v in pairs(worker) do
                if k ~= "pid" and k ~= "start_time" and k ~= "stop_time" then
                    r:puts("<th style='cursor:pointer;' onclick=\"sort(document.getElementById('server_",i,"'), ", p, ");\">",k,"</th>");
                end
                p = p + 1;
            end
            r:puts[[</tr>]]
            for j = 0, maxThreads-1 do
                worker = r.scoreboard_worker(r,i, j)
                if worker then

                    r:puts("<tr>");
                    for k, v in pairs(worker) do
                        if ( k == "last_used" and v > 3600) then v = os.date("%c", v/1000000) end
                        if k == "tid" then v = string.format("0x%x", v) end
                        if k == "status" then v = ({'D','.','R','W','K','L','D','C','G','I'})[tonumber(v)] or "??" end
                        if v == "" then v = "N/A" end
                        if k == "client" then v = v:gsub("[a-f0-9]+[.:]+[a-f0-9]+$", "x.x") end
                        if k ~= "pid" and k ~= "start_time" and k ~= "stop_time" then r:puts("<td>",v,"</td>"); end
                    end
                    r:puts("</tr>");
                end
            end
            r:puts[[</table><hr/></div>]]
        end
    end

    -- Get loaded modules
    r:puts("<div id='modules'>")
    local loaded_modules
    for k, module in pairs(r:loaded_modules()) do
        r:puts("<div><a href=\"?module=" .. module .. "\" target=\"_blank\">" .. module .. "</a></div>\n")
    end
    r:puts("</div>")

    -- HTML tail
    r:puts[[
  </body>
</html>
]]
    return apache2.OK;
end


------------------------------------
-- JavaScript and CSS definitions --
------------------------------------

-- Set up some JavaScripts:
status_js = [==[
Number.prototype.pad = function(size) {
    var str = String(this);
    while (str.length < size) {
        str = "0" + str;
    }
    return str;
}

function getAsync(theUrl, xstate, callback) {
    var xmlHttp = null;
    if (window.XMLHttpRequest) {
	xmlHttp = new XMLHttpRequest();
    } else {
	xmlhttp = new ActiveXObject("Microsoft.XMLHTTP");
    }
    xmlHttp.open("GET", theUrl, true);
    xmlHttp.send(null);
    xmlHttp.onreadystatechange = function(state) {
        if (xmlHttp.readyState == 4 && xmlHttp.status == 200) {
            if (callback) {
                callback(JSON.parse(xmlHttp.responseText));
            }
            
        }
    }
}

var actionCache = [];
var trafficCache = [];
var lastBytes = 0;
var updateSpeed = 5; // How fast do charts update?
var maxRecords = 15; // How many records to show per chart
var cpumax = 250000; // random cpu max(?)

function refreshCharts(json, state) {
    if (json && json.states) {
        
        // Get a timestamp
        var now = new Date();
        var ts = now.getHours().pad(2) + ":" + now.getMinutes().pad(2) + ":" + now.getSeconds().pad(2);
        
        // Push action state entry into action cache with timestamp
        // Shift if more than 10 entries in cache
        json.states['timestamp'] = ts;
        actionCache.push(json.states);
        if (actionCache.length > maxRecords) {
            actionCache.shift();
        }
        
        // construct array for QuokkaLines
        var arr = [];
        for (var i in actionCache) {
            var el = actionCache[i];
            arr.push([el.timestamp, el.keepalive, el.closing, el.idle, el.writing, el.reading, el.graceful]);
        }
        // Draw action chart
        quokkaLines("actions_div", ['Keepalive', 'Closing', 'Idle', 'Writing', 'Reading', 'Graceful'], arr, { lastsum: true, hires: true, nosum: true, stack: true, curve: false, title: "Thread states" } );
        
        
        // Get traffic, figure out how much it was this time (0 if just started!)
        var bytesThisTurn = json.bytes - lastBytes
        if (lastBytes == 0 || bytesThisTurn < 0) {
            bytesThisTurn = 0;
        }
        lastBytes = json.bytes
        // Push a new element into cache, prune cache
        var el = {
            timestamp: ts,
            bytes: bytesThisTurn/updateSpeed
        };
        trafficCache.push(el);
        if (trafficCache.length > maxRecords) {
            trafficCache.shift();
        }
        
        // construct array for QuokkaLines
        arr = [];
        for (var i in trafficCache) {
            var el = trafficCache[i];
            arr.push([el.timestamp, el.bytes]);
        }
        // Draw action chart
        quokkaLines("traffic_div", ['Traffic'], arr, { traffic: true, hires: true, nosum: true, stack: true, curve: false, title: "Traffic per second" } );
        
        
        // Thread info
        quokkaCircle("status_div", [ { title: 'Active', value: (json.threads*json.servers)}, { title: 'Reserve', value: (json.threads*(json.maxServers-json.servers))} ], { title: "Worker pool", hires: true});
        
        // CPU info
        while ( (json.systime+json.utime) > cpumax ) {
            cpumax = cpumax * 2;
        }

        quokkaCircle("cpu_div", [
            { title: 'Idle', value: (cpumax - json.systime - json.utime) / (cpumax/100)},
            { title: 'System', value: json.systime/(cpumax/100)},
            { title: 'User', value: json.utime/(cpumax/100)}
            ],
            { hires: true, title: "CPU usage", pct: true});
        
        
        // Change connection/transfer info
        var obj = document.getElementById("connections");
        obj.innerHTML = fn(json.connections) + " (" + Math.floor(json.connections/json.uptime*1000)/1000 + "/sec)";
        var MB = fnmb(json.bytes);
        var KB = (bytesTransfered > 0) ? fnmb(json.bytes/json.connections) : 0;
        var KBs = fnmb(json.bytes/json.uptime);
        obj = document.getElementById("transfer");
        obj.innerHTML = MB + " (" + KB + "/req, " + KBs + "/sec)";

        
        // Active vs reserved threads
        var activeThreads = json.servers * json.threads;
        var maxThreads = json.maxServers * json.threads;
        var reservedThreads = (json.maxServers-json.servers) * json.threads;
        obj = document.getElementById("current_threads");
        obj.innerHTML = activeThreads + " (" + json.servers + " processes x " + json.threads + " threads)";
        obj = document.getElementById("max_threads");
        obj.innerHTML = maxThreads + " (" + json.maxServers + " processes x " + json.threads + " threads)";

        // Uptime calculation
        var uptime_div = document.getElementById('uptime');
        var u_d = Math.floor(json.uptime/86400);
        var u_h = Math.floor((json.uptime%%86400)/3600);
        var u_m = Math.floor((json.uptime%%3600)/60);
        var u_s = Math.floor(json.uptime %%60);
        var str =  u_d + " day" + (u_d != 1 ? "s, " : ", ") + u_h + " hour" + (u_h != 1 ? "s, " : ", ") + u_m + " minute" + (u_m != 1 ? "s, " : ", ") + u_s + " second" + (u_s != 1 ? "s" : "");
        uptime_div.innerHTML = str;
        window.setTimeout(waitTwo, updateSpeed*1000);
    } else if (json === false) {
        waitTwo();
    }
}

function waitTwo() {
    getAsync(location.href + "?view=json_status&rnd=" + Math.random(), null, refreshCharts)
}

    
    function fn(num) {
        num = num + "";
        num = num.replace(/(\d)(\d{9})$/, '$1,$2');
        num = num.replace(/(\d)(\d{6})$/, '$1,$2');
        num = num.replace(/(\d)(\d{3})$/, '$1,$2');
        return num;
    }

    function fnmb(num) {
        var add = "bytes";
        var dec = "";
        var mul = 1;
        if (num > 1024) { add = "KB"; mul= 1024; }
        if (num > (1024*1024)) { add = "MB"; mul= 1024*1024; }
        if (num > (1024*1024*1024)) { add = "GB"; mul= 1024*1024*1024; }
        if (num > (1024*1024*1024*1024)) { add = "TB"; mul= 1024*1024*1024*1024; }
        num = num / mul;
        if (add != "bytes") {
            dec = "." + Math.floor( (num - Math.floor(num)) * 100 );
        }
        return ( fn(Math.floor(num)) + dec + " " + add );
    }

    function sort(a,b){
        last_col = -1;
        var sort_reverse = false;
        var sortWay = a.getAttribute("sort_" + b);
        if (sortWay && sortWay == "forward") {
            a.setAttribute("sort_" + b, "reverse");
            sort_reverse = true;
        }
        else {
            a.setAttribute("sort_" + b, "forward");
        }
        var c,d,e,f,g,h,i;
        c=a.rows.length;
        if(c<1){ return; }
        d=a.rows[1].cells.length;
        e=1;
        var j=new Array(c);
        f=0;
        for(h=e;h<c;h++){
            var k=new Array(d);
            for(i=0;i<d;i++){
                cell_text="";
                cell_text=a.rows[h].cells[i].textContent;
                if(cell_text===undefined){cell_text=a.rows[h].cells[i].innerText;}
                k[i]=cell_text;
            }
            j[f++]=k;
        }
        var l=false;
        var m,n;
        if(b!=lastcol) lastseq="A";
        else{
            if(lastseq=="A") lastseq="D";
            lastseq="A";
        }

        g=c-1;

        for(h=0;h<g;h++){
            l=false;
            for(i=0;i<g-1;i++){
                m=j[i];
                n=j[i+1];
                if(lastseq=="A"){
                    var gt = (m[b]>n[b]) ? true : false;
                    var lt = (m[b]<n[b]) ? true : false;
                    if (n[b].match(/^(\d+)$/)) { gt = parseInt(m[b], 10) > parseInt(n[b], 10) ? true : false; lt = parseInt(m[b], 10) < parseInt(n[b], 10) ? true : false; }
                    if (sort_reverse) {gt = (!gt); lt = (!lt);}
                    if(gt){
                        j[i+1]=m;
                        j[i]=n;
                        l=true;
                    }
                }
                else{
                    if(lt){
                        j[i+1]=m;
                        j[i]=n;
                        l=true;
                    }
                }
            }
            if(l===false){
                break;
            }
        }
        f=e;
        for(h=0;h<g;h++){
            m=j[h];
            for(i=0;i<d;i++){
                if(a.rows[f].cells[i].innerText!==undefined){
                    a.rows[f].cells[i].innerText=m[i];
                }
                else{
                    a.rows[f].cells[i].textContent=m[i];
                }
            }
            f++;
        }
        lastcol=b;
    }

    
    var currentServers =    %u;
    var maxServers =        %u;
    var threadsPerProcess = %u;


    var threadsIdle =       %u;
    var threadsWriting =    %u;
    var threadsReading =    %u;
    var threadsKeepalive =  %u;
    var threadsClosing =    %u;
    var threadsGraceful =   %u;

    var cpuIdle =           %u;
    var cpuSystem =         0;
    var cpuUser =           0;
    var cpuSystemTotal =    %u;
    var cpuUserTotal =      %u;
    var CPUmax =            100000;

    var connections =       %u;
    var uptime =            %u;
    var bytesTransfered =   %u;
    var bytesDifferenceIn = 0;
    var bytesDifferenceOut = 0;

    var pool_data;
    var pool_chart;
    var pool_options;

    var status_data;
    var status_chart;
    var status_options;

    var cpu_data;
    var cpu_chart;
    var cpu_options;

    var traffic_chart;
    var traffic_data;
    var traffic_options;

    var costs = [];
    var arr;

    
    var showing = false;
    function showDetails() {
        for (i=1; i < 1000; i++) {
            var obj = document.getElementById("srv_" + i);
            if (obj) {
                if (showing) { obj.style.display = "none"; }
                else { obj.style.display = "block"; }
            }
        }
        var link = document.getElementById("show_link");
        showing = (!showing);
        if (showing) { link.innerHTML = "Hide thread information"; }
        else { link.innerHTML = "Show thread information"; }
    }

    var showing_modules = false;
    function show_modules() {

        var obj = document.getElementById("modules");
        if (obj) {
            if (showing_modules) { obj.style.display = "none"; }
            else { obj.style.display = "block"; }
        }
        var link = document.getElementById("show_modules_link");
        showing_modules = (!showing_modules);
        if (showing_modules) { link.innerHTML = "Hide loaded modules"; }
        else { link.innerHTML = "Show loaded modules"; }
    }
]==]

quokka_js = [==[
/*
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Traffic shaper
function quokka_fnmb(num) {
    var add = "b";
    var dec = "";
    var mul = 1;
    if (num > 1024) { add = "KB"; mul= 1024; }
    if (num > (1024*1024)) { add = "MB"; mul= 1024*1024; }
    if (num > (1024*1024*1024)) { add = "GB"; mul= 1024*1024*1024; }
    if (num > (1024*1024*1024*1024)) { add = "TB"; mul= 1024*1024*1024*1024; }
    num = num / mul;
    if (add != "b" && num < 10) {
        dec = "." + Math.floor( (num - Math.floor(num)) * 100 );
    }
    return ( Math.floor(num) + dec + " " + add );
}

// Hue, Saturation and Lightness to Red, Green and Blue:
function quokka_internal_hsl2rgb (h,s,l)
{
    var min, sv, switcher, fract, vsf;
    h = h % 1;
    if (s > 1) s = 1;
    if (l > 1) l = 1;
    var v = (l <= 0.5) ? (l * (1 + s)) : (l + s - l * s);
    if (v === 0)
        return { r: 0, g: 0, b: 0 };

    min = 2 * l - v;
    sv = (v - min) / v;
    var sh = (6 * h) % 6;
    switcher = Math.floor(sh);
    fract = sh - switcher;
    vsf = v * sv * fract;

    switch (switcher)
    {
        case 0: return { r: v, g: min + vsf, b: min };
        case 1: return { r: v - vsf, g: v, b: min };
        case 2: return { r: min, g: v, b: min + vsf };
        case 3: return { r: min, g: v - vsf, b: v };
        case 4: return { r: min + vsf, g: min, b: v };
        case 5: return { r: v, g: min, b: v - vsf };
    }
    return {r:0, g:0, b: 0};
}

// RGB to Hex conversion
function quokka_internal_rgb2hex(r, g, b) {
    return "#" + ((1 << 24) + (Math.floor(r) << 16) + (Math.floor(g) << 8) + Math.floor(b)).toString(16).slice(1);
}


// Generate color list used for charts
var colors = [];
var rgbs = []
var numColorRows = 6;
var numColorColumns = 20;
for (var x=0;x<numColorRows;x++) {
    for (var y=0;y<numColorColumns;y++) {
        var rnd = [[148, 221, 119], [0, 203, 171], [51, 167, 215] , [35, 160, 253], [218, 54, 188], [16, 171, 246], [110, 68, 206], [21, 49, 248], [142, 104, 210]][y]
        var color = quokka_internal_hsl2rgb(y > 8 ? (Math.random()) : (rnd[0]/255), y > 8 ? (0.75+(y*0.05)) : (rnd[1]/255), y > 8 ? (0.42 + (y*0.05*(x/numColorRows))) : (0.1 + rnd[2]/512));
        
        // Light (primary) color:
        var hex = quokka_internal_rgb2hex(color.r*255, color.g*255, color.b*255);
        
        // Darker variant for gradients:
        var dhex = quokka_internal_rgb2hex(color.r*111, color.g*111, color.b*111);
        
        colors.push([hex, dhex, color]);
    }
}


/* Function for drawing pie diagrams
 * Example usage:
 * quokkaCircle("canvasName", [ { title: 'ups', value: 30}, { title: 'downs', value: 70} ] );
 */

function quokkaCircle(id, tags, opts) {
    // Get Canvas object and context
    var canvas = document.getElementById(id);
    var ctx=canvas.getContext("2d");
    
    // Calculate the total value of the pie
    var total = 0;
    var k;
    for (k in tags) {
        tags[k].value = Math.abs(tags[k].value);
        total += tags[k].value;
    }
    
    
    
    // Draw the empty pie
    var begin = 0;
    var stop = 0;
    var radius = (canvas.height*0.75)/2;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.shadowBlur = 4;
    ctx.shadowOffsetX = 0.5;
    ctx.shadowOffsetY = 0.6;
    ctx.shadowColor = "#666";
    
    ctx.arc((canvas.width-140)/2,canvas.height/2,radius, 0, Math.PI * 2);
    ctx.closePath();
    ctx.stroke();
    ctx.shadowBlur = 0;
    
    
    // Draw a title if set:
    if (opts && opts.title) {
        ctx.font= (opts && opts.hires) ? "24px Sans-Serif" : "15px Sans-Serif";
        ctx.fillStyle = "#000000";
        ctx.textAlign = "center";
        ctx.fillText(opts.title,(canvas.width-140)/2, (opts && opts.hires) ? 30:15);
        ctx.textAlign = "left";
    }
    
    ctx.beginPath();
    var posY = 20;
    var left = 140 + ((canvas.width-140)/2) + 20
    for (k in tags) {
        var val = tags[k].value;
        stop = stop + (2 * Math.PI * (val / total));
        
        // Make a pizza slice
        ctx.beginPath();
        ctx.lineCap = 'round';
        ctx.arc((canvas.width-140)/2,canvas.height/2,radius,begin,stop);
        ctx.lineTo((canvas.width-140)/2,canvas.height/2);
        ctx.closePath();
        ctx.lineWidth = 0;
        ctx.stroke();
        
        // Add color gradient
        var grd=ctx.createLinearGradient(0,0,170,0);
        grd.addColorStop(0,colors[k % colors.length][1]);
        grd.addColorStop(1,colors[k % colors.length][0]);
        ctx.fillStyle = grd
        ctx.fill();
        begin = stop;
        
        // Make color legend
        ctx.fillRect(left, posY-((opts && opts.hires) ? 15 : 10), (opts && opts.hires) ? 14 : 7, (opts && opts.hires) ? 14 : 7);
        
        // Add legend text
        ctx.shadowColor = "rgba(0,0,0,0)"
        ctx.font= (opts && opts.hires) ? "20px Sans-Serif" : "10px Sans-Serif";
        ctx.fillStyle = "#000";
        ctx.fillText(tags[k].title + " (" + Math.floor(val) + (opts && opts.pct ? "%" : "") + ")",left+20,posY);
        
        posY += (opts && opts.hires) ? 28 : 14;
    }
    
}


/* Function for drawing line charts
 * Example usage:
 * quokkaLines("myCanvas", ['Line a', 'Line b', 'Line c'], [ [x1,a1,b1,c1], [x2,a2,b2,c2], [x3,a3,b3,c3] ], { stacked: true, curve: false, title: "Some title" } );
 */
function quokkaLines(id, titles, values, options, sums) {
    var canvas = document.getElementById(id);
    var ctx=canvas.getContext("2d");
    // clear the canvas first
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    
    


    ctx.lineWidth = 0.25;
    ctx.strokeStyle = "#000000";
    
    var lwidth = 250;
    var lheight = 75;
    wspace = (options && options.hires) ? 100 : 50;
    var rectwidth = canvas.width - lwidth - wspace;
    var stack = options ? options.stack : false;
    var curve = options ? options.curve : false;
    var title = options ? options.title : null;
    var spots = options ? options.points : false;
    var noX = options ? options.nox : false;
    var verts = options ? options.verts : true;
    if (noX) {
        lheight = 0;
    }
    
    
    // calc rectwidth if titles are large
    var nlwidth = 0
    for (var k in titles) {
        ctx.font= (options && options.hires) ? "20px Sans-Serif" : "12px Sans-Serif";
        ctx.fillStyle = "#00000";
        var x = parseInt(k)
        if (!noX) {
            x = x + 1;
        }
        var sum = 0
        for (var y in values) {
            sum += values[y][x]
        }
        var t = titles[k] + (!options.nosum ? " (" + ((sums && sums[k]) ? sums[k] : sum.toFixed(0)) + ")" : "");
        var w = ctx.measureText(t).width + 48;
        if (w > lwidth && w > nlwidth) {
            nlwidth = w
        }
        if (nlwidth > 0) {
            rectwidth -= nlwidth - lwidth
            lwidth = nlwidth
        }
    }
    
    // Draw a border
    ctx.lineWidth = 0.5;
    ctx.strokeRect((wspace*0.75), 30, rectwidth, canvas.height - lheight - 40);
    
    // Draw a title if set:
    if (title != null) {
        ctx.font= (options && options.hires) ? "20px Sans-Serif" : "15px Sans-Serif";
        ctx.fillStyle = "#00000";
        ctx.textAlign = "center";
        ctx.fillText(title,rectwidth/2, 15);
    }
    
    // Draw legend
    ctx.textAlign = "left";
    var posY = 50;
    for (var k in titles) {
        var x = parseInt(k)
        if (!noX) {
            x = x + 1;
        }
        var sum = 0
        for (var y in values) {
            sum += values[y][x]
        }
        
        var title = titles[k] + (!options.nosum ? (" (" + ((sums && sums[k]) ? sums[k] : sum.toFixed(0)) + ")") : "");
        if (options && options.lastsum) {
            title = titles[k] + " (" + values[values.length-1][x].toFixed(0) + ")";
        }
        ctx.fillStyle = colors[k % colors.length][0];
        ctx.fillRect(wspace + rectwidth + 75 , posY-((options && options.hires) ? 15:9), (options && options.hires) ? 20:10, (options && options.hires) ?20:10);
        
        // Add legend text
        ctx.font= (options && options.hires) ? "20px Sans-Serif" : "12px Sans-Serif";
        ctx.fillStyle = "#00000";
        ctx.fillText(title,canvas.width - lwidth + ((options && options.hires) ? 100:60), posY);
        
        posY += (options && options.hires) ? 30:15;
    }
    
    // Find max and min
    var max = null;
    var min = 0;
    var stacked = null;
    for (x in values) {
        var s = 0;
        for (y in values[x]) {
            if (y > 0 || noX) {
                s += values[x][y];
                if (max == null || max < values[x][y]) {
                    max = values[x][y];
                }
                if (min == null || min > values[x][y]) {
                    min = values[x][y];
                }
            }
        }
        if (stacked == null || stacked < s) {
            stacked = s;
        }
    }
    if (stack) {
        min = 0;
        max = stacked;
    }
    
    
    // Set number of lines to draw and each step
    var numLines = 5;
    var step = (max-min) / (numLines+1);
    
    // Prettify the max value so steps aren't ugly numbers
    if (step %1 != 0) {
        step = (Math.round(step+0.5));
        max = step * (numLines+1);
    }
    
    // Draw horizontal lines
    
    for (x = -1; x <= numLines; x++) {
        ctx.beginPath();
        var y = 30 + (((canvas.height-40-lheight) / (numLines+1)) * (x+1));
        ctx.moveTo(wspace*0.75, y);
        ctx.lineTo(wspace*0.75 + rectwidth, y);
        ctx.lineWidth = 0.25;
        ctx.stroke();
        
        // Add values
        ctx.font= (options && options.hires) ? "16px Sans-Serif" : "10px Sans-Serif";
        ctx.fillStyle = "#000000";
        
        var val = Math.round( ((max-min) - (step*(x+1))) );
        if (options && options.traffic) {
            val = quokka_fnmb(val);
        }
        ctx.textAlign = "left";
        ctx.fillText( val,canvas.width - lwidth - 10, y+8);
        ctx.textAlign = "right";
        ctx.fillText( val,wspace-30, y+8);
        ctx.closePath();
    }
    
    
    
    // Draw vertical lines
    var sx = 1
    var numLines = values.length-1;
    var step = (canvas.width - lwidth - wspace*0.75) / values.length;
    while (step < 24) {
        step *= 2
        sx *= 2
    }
    
    
    if (verts) {
        ctx.beginPath();
        for (var x = 1; x < values.length; x++) {
            if (x % sx == 0) {
                var y = (wspace*0.75) + (step * (x/sx));
                ctx.moveTo(y, 30);
                ctx.lineTo(y, canvas.height - 10 - lheight);
                ctx.lineWidth = 0.25;
                ctx.stroke();
            }
        }
        ctx.closePath();
    }
    
    
    
    // Some pre-calculations of steps
    var step = (rectwidth) / (values.length > 1 ? values.length-1:1);
    
    // Draw X values if noX isn't set:
    if (noX != true) {
        ctx.beginPath();
        for (var i = 0; i < values.length; i++) {
            zz = 1
            var x = (wspace*0.75) + ((step) * i);
            var y = canvas.height - lheight + 5;
            if (i % sx == 0) {
                ctx.translate(x, y);
                ctx.moveTo(0,0);
                ctx.lineTo(0,-15);
                ctx.stroke();
                ctx.rotate(45*Math.PI/180);
                ctx.textAlign = "left";
                var val = values[i][0];
                if (val.constructor.toString().match("Date()")) {
                    val = val.toDateString();
                }
                ctx.fillText(val.toString(), 0, 0);
                ctx.rotate(-45*Math.PI/180);
                ctx.translate(-x,-y);
            }
        }
        ctx.closePath();
        
    }
    
    
    
    
    // Draw each line
    var stacks = [];
    var pstacks = [];
    for (k in values) { if (k > 0) { stacks[k] = 0; pstacks[k] = canvas.height - 40 - lheight; }}
    
    for (k in titles) {
        ctx.beginPath();
        var color = colors[k % colors.length][0];
        var f = parseInt(k) + 1;
        if (noX) {
            f = parseInt(k);
        }
        var value = values[0][f];
        var step = rectwidth / numLines;
        var x = (wspace*0.75);
        var y = (canvas.height - 10 - lheight) - (((value-min) / (max-min)) * (canvas.height - 40 - lheight));
        var py = y;
        if (stack) {
            stacks[0] = stacks[0] ? stacks[0] : 0
            y -= stacks[0];
            pstacks[0] = stacks[0];
            stacks[0] += (((value-min) / (max-min)) * (canvas.height - 40 - lheight));
        }
        
        // Draw line
        ctx.moveTo(x, y);
        var pvalY = y;
        var pvalX = x;
        for (var i in values) {
            if (i > 0) {
                x = (wspace*0.75) + (step*i);
                var f = parseInt(k) + 1;
                if (noX == true) {
                    f = parseInt(k);
                }
                value = values[i][f];
                y = (canvas.height - 10 - lheight) - (((value-min) / (max-min)) * (canvas.height - 40 - lheight));
                if (stack) {
                    y -= stacks[i];
                    pstacks[i] = stacks[i];
                    stacks[i] += (((value-min) / (max-min)) * (canvas.height - 40- lheight));
                }
                // Draw curved lines??
                /* We'll do: (x1,y1)-----(x1.5,y1)
                 *                          |
                 *                       (x1.5,y2)-----(x2,y2)
                 * with a quadratic beizer thingy
                */
                if (curve) {
                    ctx.bezierCurveTo((pvalX + x) / 2, pvalY, (pvalX + x) / 2, y, x, y);
                    pvalX = x;
                    pvalY = y;
                }
                // Nope, just draw straight lines
                else {
                    ctx.lineTo(x, y);
                }
                if (spots) {
                    ctx.fillStyle = color;
                    ctx.translate(x-2, y-2);
                    ctx.rotate(-45*Math.PI/180);
                    ctx.fillRect(-2,1,4,4);
                    ctx.rotate(45*Math.PI/180);
                    ctx.translate(-x+2, -y+2);
                }
            }
        }
        
        ctx.lineWidth = 4;
        ctx.strokeStyle = color;
        ctx.stroke();
        
        
        
        
        // Draw stack area
        if (stack) {
            ctx.globalAlpha = 0.65;
            for (i in values) {
                if (i > 0) {
                    var f = parseInt(k) + 1;
                    if (noX == true) {
                        f = parseInt(k);
                    }
                    x = (wspace*0.75) + (step*i);
                    value = values[i][f];
                    y = (canvas.height - 10 - lheight) - (((value-min) / (max-min)) * (canvas.height - 40 - lheight));
                    y -= stacks[i];
                }
            }
            var pvalY = y;
            var pvalX = x;
            for (i in values) {
                var l = values.length - i - 1;
                x = (wspace*0.75) + (step*l);
                y = canvas.height - 10 - lheight - pstacks[l];

                if (curve) {
                    ctx.bezierCurveTo((pvalX + x) / 2, pvalY, (pvalX + x) / 2, y, x, y);
                    pvalX = x;
                    pvalY = y;
                }
                else {
                    ctx.lineTo(x, y);
                }
            }
            ctx.lineTo((wspace*0.75), py - pstacks[0]);
            ctx.lineWidth = 0;
            ctx.strokeStyle = colors[k % colors.length][0];
            ctx.fillStyle = colors[k % colors.length][0];
            ctx.fill();
            ctx.fillStyle = "#000"
            ctx.strokeStyle = "#000"
            ctx.globalAlpha = 1;
        }
        ctx.closePath();
    }
    
    // draw feather
    base_image = new Image();
    base_image.src = 'data:image/png;base64,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';
    base_image.onload = function(){
        ctx.globalAlpha = 0.15
        ctx.drawImage(base_image, (canvas.width/2) - 64 - (lwidth/2), (canvas.height/2) - 128);
        ctx.globalAlpha = 1
    }
}



/* Function for drawing line charts
 * Example usage:
 * quokkaLines("myCanvas", ['Line a', 'Line b', 'Line c'], [ [x1,a1,b1,c1], [x2,a2,b2,c2], [x3,a3,b3,c3] ], { stacked: true, curve: false, title: "Some title" } );
 */
function quokkaBars(id, titles, values, options) {
    var canvas = document.getElementById(id);
    var ctx=canvas.getContext("2d");
    // clear the canvas first
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    var lwidth = 150;
    var lheight = 75;
    var stack = options ? options.stack : false;
    var astack = options ? options.astack : false;
    var curve = options ? options.curve : false;
    var title = options ? options.title : null;
    var noX = options ? options.nox : false;
    var verts = options ? options.verts : true;
    if (noX) {
        lheight = 0;
    }
    
    
    
    // Draw a border
    ctx.lineWidth = 0.5;
    ctx.strokeRect(25, 30, canvas.width - lwidth - 40, canvas.height - lheight - 40);
    
    // Draw a title if set:
    if (title != null) {
        ctx.font="15px Arial";
        ctx.fillStyle = "#000";
        ctx.textAlign = "center";
        ctx.fillText(title,(canvas.width-lwidth)/2, 15);
    }
    
    // Draw legend
    ctx.textAlign = "left";
    var posY = 50;
    for (var k in titles) {
        var x = parseInt(k)
        if (!noX) {
            x = x + 1;
        }
        var title = titles[k];
        if (title && title.length > 0) {
            ctx.fillStyle = colors[k % colors.length][0];
            ctx.fillRect(canvas.width - lwidth + 20, posY-10, 10, 10);
            
            // Add legend text
            ctx.font="12px Arial";
            ctx.fillStyle = "#000";
            ctx.fillText(title,canvas.width - lwidth + 40, posY);
            
            posY += 15;
        }
        

    }
    
    // Find max and min
    var max = null;
    var min = 0;
    var stacked = null;
    for (x in values) {
        var s = 0;
        for (y in values[x]) {
            if (y > 0 || noX) {
                s += values[x][y];
                if (max == null || max < values[x][y]) {
                    max = values[x][y];
                }
                if (min == null || min > values[x][y]) {
                    min = values[x][y];
                }
            }
        }
        if (stacked == null || stacked < s) {
            stacked = s;
        }
    }
    if (stack) {
        min = 0;
        max = stacked;
    }
    
    
    // Set number of lines to draw and each step
    var numLines = 5;
    var step = (max-min) / (numLines+1);
    
    // Prettify the max value so steps aren't ugly numbers
    if (step %1 != 0) {
        step = (Math.round(step+0.5));
        max = step * (numLines+1);
    }
    
    // Draw horizontal lines
    for (x = numLines; x >= 0; x--) {
        
        var y = 30 + (((canvas.height-40-lheight) / (numLines+1)) * (x+1));
        ctx.moveTo(25, y);
        ctx.lineTo(canvas.width - lwidth - 15, y);
        ctx.lineWidth = 0.25;
        ctx.stroke();
        
        // Add values
        ctx.font="10px Arial";
        ctx.fillStyle = "#000";
        ctx.textAlign = "right";
        ctx.fillText( Math.round( ((max-min) - (step*(x+1))) * 100 ) / 100,canvas.width - lwidth + 12, y-4);
        ctx.fillText( Math.round( ((max-min) - (step*(x+1))) * 100 ) / 100,20, y-4);
    }
    
    
    // Draw vertical lines
    var sx = 1
    var numLines = values.length-1;
    var step = (canvas.width - lwidth - 40) / values.length;
    while (step < 24) {
        step *= 2
        sx *= 2
    }
    
    
    if (verts) {
        ctx.beginPath();
        for (var x = 1; x < values.length; x++) {
            if (x % sx == 0) {
                var y = 35 + (step * (x/sx));
                ctx.moveTo(y, 30);
                ctx.lineTo(y, canvas.height - 10 - lheight);
                ctx.lineWidth = 0.25;
                ctx.stroke();
            }
        }
    }
    
    
    
    // Some pre-calculations of steps
    var step = (canvas.width - lwidth - 48) / values.length;
    var smallstep = (step / titles.length) - 2;
    
    // Draw X values if noX isn't set:
    if (noX != true) {
        ctx.beginPath();
        for (var i = 0; i < values.length; i++) {
            smallstep = (step / (values[i].length-1)) - 2;
            zz = 1
            var x = 35 + ((step) * i);
            var y = canvas.height - lheight + 5;
            if (i % sx == 0) {
                ctx.translate(x, y);
                ctx.moveTo(0,0);
                ctx.lineTo(0,-15);
                ctx.stroke();
                ctx.rotate(45*Math.PI/180);
                ctx.textAlign = "left";
                var val = values[i][0];
                if (val.constructor.toString().match("Date()")) {
                    val = val.toDateString();
                }
                ctx.fillText(val.toString(), 0, 0);
                ctx.rotate(-45*Math.PI/180);
                ctx.translate(-x,-y);
            }
        }
        
    }
    
    
    
    
    // Draw each line
    var stacks = [];
    var pstacks = [];
    
    for (k in values) {
        smallstep = (step / (values[k].length)) - 2;
        stacks[k] = 0;
        pstacks[k] = canvas.height - 40 - lheight;
        var beginX = 0;
        for (i in values[k]) {
            if (i > 0 || noX) {
                var z = parseInt(i);
                var zz = z;
                if (!noX) {
                    z = parseInt(i) + 1;
                    zz = z - 2;
                    if (z > values[k].length) {
                        break;
                    }
                }
                var value = values[k][i];
                var title = titles[i];
                var color = colors[zz % colors.length][1];
                var fcolor = colors[zz % colors.length][2];
                if (values[k][2] && values[k][2].toString().match(/^#.+$/)) {
                    color = values[k][2]
                    fcolor = values[k][2]
                    smallstep = (step / (values[k].length-2)) - 2;
                }
                var x = ((step) * k) + ((smallstep+2) * zz) + 5;
                var y = canvas.height - 10 - lheight;
                var height = ((canvas.height - 40 - lheight) / (max-min)) * value * -1;
                var width = smallstep - 2;
                if (width <= 1) {
                    width = 1
                }
                if (stack) {
                    width = step - 10;
                    y -= stacks[k];
                    stacks[k] -= height;
                    x = (step * k) + 4;
                    if (astack) {
                        y = canvas.height - 10 - lheight;
                    }
                }
                
                        
                // Draw bar
                ctx.beginPath();
                ctx.lineWidth = 2;
                ctx.strokeStyle = color;
                ctx.strokeRect(27 + x, y, width, height);
                var alpha = 0.75
                if (fcolor.r) {
                    ctx.fillStyle = 'rgba('+ [parseInt(fcolor.r*255),parseInt(fcolor.g*255),parseInt(fcolor.b*255),alpha].join(",") + ')';
                } else {
                    ctx.fillStyle = fcolor;
                }
                ctx.fillRect(27 + x, y, width, height);
                
            }
        }
        

    }
}


]==]


status_css = [[
    html {
    font-size: 14px;
    margin: 20px;
    }

    body {
        background-color: #fff;
        color: #036;
        padding: 0 1em 0 0;
        margin: 0;
        font-family: Arial, Helvetica, sans-serif;
        font-weight: normal;
    }

    pre, code {
        font-family: "Courier New", Courier, monospace;
    }

    strong {
        font-weight: bold;
    }

    q, em, var {
        font-style: italic;
    }
    /* h1                     */
    /* ====================== */
    h1 {
        padding: 0.2em;
        margin: 0;
        border: 1px solid #405871;
        background-color: inherit;
        color: #036;
        text-decoration: none;
        font-size: 22px;
        font-weight: bold;
    }

    /* h2                     */
    /* ====================== */
    h2 {
        padding: 0.2em 0 0.2em 0.7em;
        margin: 0 0 0.5em 0;
        text-decoration: none;
        font-size: 18px;
        font-weight: bold;
        background-color: #405871;
        color: #fff;
    }

    #modules {
        margin-top:20px;
        display:none;
        width:400px;
    }

    #modules div:nth-of-type(even), .servers table tr:nth-of-type(even){
        background-color:#fff;
    }

    #modules div:nth-of-type(odd), .servers table tr:nth-of-type(odd){
        background-color:#cecece;
    }

]]