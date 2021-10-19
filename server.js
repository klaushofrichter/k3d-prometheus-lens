//
// simple random server
//

const package = require("./package.json");
const express = require("express");
const os = require("os");
const chance=require("chance").Chance();

// setup express worker
const worker = express();
const workerPort = 3000;

// create the info JSON with interesting information 
const info = {
  launchDate: new Date().toLocaleString("en-US", { timeZone: "America/Chicago" }),
  serverName: chance.first() + " the " + chance.animal(),
  appName: package.name,
  serverVersion: package.version
};

// setup metrics 
const promBundle = require("express-prom-bundle");
const metricsMiddleware = promBundle({
  includePath: true,
  includeMethod: true,
  includeUp: true,
  metricsPath: "/service/metrics",
  httpDurationMetricName: package.name + "_http_request_duration_seconds",
});
worker.use("/*", metricsMiddleware);

const prom = require("prom-client");
const infoGauge = new prom.Gauge({
  name: package.name + "_server_info",
  help: package.name + " server info provides build and runtime information",
  labelNames: [
    "launchDate",
    "serverName",
    "appName",
    "serverVersion",
  ],
});
infoGauge.set(info, 1);
prom.register.metrics();

worker.get("/service/info", (req, res) => {
  res.status(200).send(info);
});

worker.get("/service/random", (req, res) => { 
  res.status(200).send({ random: Math.floor((Math.random()*100))});
});

// start listening on express routes
worker.listen(workerPort, () => {
  console.log("server listening on http://localhost:%s/service/", workerPort);
  console.log(info);
});
