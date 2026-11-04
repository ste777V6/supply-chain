# syntax=docker/dockerfile:1
# Multi-stage build. The runtime image contains NO package installer (pip):
# pip isn't needed to run the app, and every copy shipped is attack surface
# that scanners (rightly) report. Verified against the official python image
# source (docker-library/python, 3.12/slim-*): pip comes from --with-ensurepip
# plus a /usr/local/bin/pip symlink; no setuptools/wheel.
# Hardening step for later: pin the base image by digest
# (python:3.12-slim@sha256:...) and let Dependabot's "docker" ecosystem bump it.

FROM python:3.12-slim AS builder
WORKDIR /build
# Venv created WITHOUT pip; the builder's own pip installs into it via --python.
RUN python -m venv --without-pip /opt/venv
COPY requirements.txt .
RUN pip --python /opt/venv/bin/python install --no-cache-dir -r requirements.txt

FROM python:3.12-slim
ARG GIT_SHA=unknown
ENV GIT_SHA=${GIT_SHA} \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
# Remove the base image's pip (and its leftover symlink) from the runtime image.
RUN python -m pip uninstall -y pip \
 && rm -f /usr/local/bin/pip \
 && useradd --system --uid 10001 --no-create-home appuser
WORKDIR /srv
COPY --from=builder /opt/venv /opt/venv
COPY app/ ./app/
USER 10001
EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app.main:app"]
