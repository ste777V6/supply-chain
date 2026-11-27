# TEST ONLY - deliberately insecure Dockerfile. NEVER MERGE.
# It builds successfully, so the image gate fails on vulnerabilities, not on a build error.

# Old pinned base image: its OS packages have security fixes available in newer
# Debian updates, and the vulnerable Python packages below are installed into it.
FROM python:3.12.0-slim

# hadolint DL3000 (error): use an absolute WORKDIR
WORKDIR app

# hadolint DL3020 (error): use COPY instead of ADD for files and folders
ADD requirements.txt .

# Installs the vulnerable packages from requirements.txt (see requirements_vulnerable.txt)
RUN pip install --no-cache-dir -r requirements.txt

CMD ["python", "-c", "print('test image')"]
