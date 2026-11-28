import uWS from "uWebSockets.js";

const port = Number(process.env.PORT ?? 9001);
const maxPayloadLength = 16 * 1024 * 1024;

uWS
  .App()
  .ws("/*", {
    compression: 0,
    maxPayloadLength,
    idleTimeout: 120,
    message: (ws, message, isBinary) => {
      ws.send(message, isBinary);
    },
  })
  .listen(port, (token) => {
    if (!token) {
      console.error(`uWebSockets failed to listen on ${port}`);
      process.exit(1);
    }
    console.log(`uWebSockets listening on ${port}`);
  });
