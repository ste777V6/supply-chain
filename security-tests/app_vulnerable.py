# TEST ONLY - deliberately vulnerable code to test CodeQL and Semgrep. NEVER MERGE.
# User input from an HTTP request (a "remote source" for CodeQL) reaches
# a shell command and an SQL query without sanitisation.
import sqlite3
import subprocess

from flask import Flask, request

app = Flask(__name__)


@app.route("/ping")
def ping():
    host = request.args.get("host", "")
    # Command injection: CodeQL py/command-line-injection
    return subprocess.check_output("ping -c 1 " + host, shell=True)


@app.route("/user")
def user():
    name = request.args.get("name", "")
    conn = sqlite3.connect("app.db")
    # SQL injection: CodeQL py/sql-injection
    rows = conn.execute("SELECT * FROM users WHERE name = '" + name + "'").fetchall()
    return str(rows)
