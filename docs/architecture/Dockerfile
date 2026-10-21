# Renders architecture.py with the Python "diagrams" library (needs Graphviz). See README.md in this folder.
FROM python:3.13-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends graphviz fonts-dejavu-core >/dev/null \
 && rm -rf /var/lib/apt/lists/* && pip install -q --no-cache-dir diagrams==0.24.4
WORKDIR /work
ENTRYPOINT ["python", "architecture.py"]
