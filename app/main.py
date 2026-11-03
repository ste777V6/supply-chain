"""Minimal Flask API used as the artifact that flows through the supply-chain pipeline."""
import os

from flask import Flask, jsonify

app = Flask(__name__)


@app.get("/healthz")
def healthz():
    return jsonify(status="ok")


@app.get("/version")
def version():
    # GIT_SHA is injected at build time (see Dockerfile ARG) so the running
    # container can be traced back to the exact commit in its provenance.
    return jsonify(commit=os.environ.get("GIT_SHA", "unknown"))


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080)
