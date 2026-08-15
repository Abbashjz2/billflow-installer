const http = require("http");
const { execFile } = require("child_process");
const path = require("path");

const HOST = process.env.UPDATE_AGENT_HOST || "127.0.0.1";
const PORT = Number(process.env.UPDATE_AGENT_PORT || 3067);
const UPDATE_SCRIPT = path.join(__dirname, "update-bridge.sh");
const UPDATE_SECRET = process.env.UPDATE_AGENT_SECRET;

let updateRunning = false;

function sendJson(res, statusCode, payload) {
  res.writeHead(statusCode, {
    "Content-Type": "application/json",
  });

  res.end(JSON.stringify(payload));
}

const server = http.createServer((req, res) => {
  if (req.method !== "POST" || req.url !== "/update") {
    return sendJson(res, 404, {
      ok: false,
      error: "not_found",
    });
  }

  if (!UPDATE_SECRET) {
    return sendJson(res, 500, {
      ok: false,
      error: "update_agent_secret_not_configured",
    });
  }

  const suppliedSecret = req.headers["x-update-secret"];

  if (suppliedSecret !== UPDATE_SECRET) {
    return sendJson(res, 401, {
      ok: false,
      error: "unauthorized",
    });
  }

  if (updateRunning) {
    return sendJson(res, 409, {
      ok: false,
      error: "update_already_running",
    });
  }

  let body = "";

  req.on("data", chunk => {
    body += chunk;

    if (body.length > 10_000) {
      req.destroy();
    }
  });

  req.on("end", () => {
    let payload;

    try {
      payload = JSON.parse(body);
    } catch {
      return sendJson(res, 400, {
        ok: false,
        error: "invalid_json",
      });
    }

    const version = payload.version;

    if (
      typeof version !== "string" ||
      !/^\d+\.\d+\.\d+$/.test(version)
    ) {
      return sendJson(res, 400, {
        ok: false,
        error: "invalid_version",
      });
    }

    updateRunning = true;

    execFile(UPDATE_SCRIPT, [version], (error, stdout, stderr) => {
      updateRunning = false;

      if (error) {
        console.error(stderr || error.message);
        return;
      }

      console.log(stdout.trim());
    });

    return sendJson(res, 202, {
      ok: true,
      status: "accepted",
      version,
    });
  });
});

server.listen(PORT, HOST, () => {
  console.log(`Bridge update agent listening on http://${HOST}:${PORT}`);
});
