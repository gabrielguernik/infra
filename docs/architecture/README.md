# Architecture diagram

`architecture.py` draws `architecture.png` with the Python [diagrams](https://diagrams.mingrammer.com) library
(AWS, Kubernetes and tool icons, laid out by Graphviz). Change the code, re-render, and commit both files.

Render without installing anything locally (Docker image with Python, Graphviz and `diagrams`):

```bash
cd docs/architecture
docker build -q -t infra-diagrams .
docker run --rm -v "$PWD:/work" infra-diagrams      # writes architecture.png
```

The flow diagrams (app delivery, infrastructure delivery, secrets) are Mermaid blocks in the repository README;
GitHub renders them directly.
