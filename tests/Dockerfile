# Image for the Python side of the tests (see tests/run.sh). Scripts that run in
# geoserver are tested in the geoserver image itself, not here.
FROM python:3.12-slim
RUN pip install --no-cache-dir "pyyaml==6.*" "pytest==8.*"
WORKDIR /repo
