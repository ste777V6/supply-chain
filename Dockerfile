# syntax=docker/dockerfile:1
# Multi-stage build: dependencies are installed in a builder stage, and only
# the virtualenv + app code are copied into the runtime image.
# Hardening step for later: pin the base image by digest
# (python:3.12-slim@sha256:...) and let Dependabot's "docker" ecosystem bump it.

FROM python:3.12-slim AS builder
WORKDIR /build
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim
ARG GIT_SHA=unknown
ENV GIT_SHA=${GIT_SHA} \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
RUN useradd --system --uid 10001 --no-create-home appuser
WORKDIR /srv
COPY --from=builder /opt/venv /opt/venv
COPY app/ ./app/
USER 10001
EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app.main:app"]
