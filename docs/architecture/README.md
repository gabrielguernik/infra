# Architecture diagrams

`architecture.py` draws three pictures, `request-path.png`, `platform.png` and
`delivery-access.png`, with the Python [diagrams](https://diagrams.mingrammer.com) library
(AWS, Kubernetes and tool icons, laid out by Graphviz). Change the code, re-render, and commit the code and the images.

Render without installing anything locally (Docker image with Python, Graphviz and `diagrams`):

```bash
cd docs/architecture
docker build -q -t infra-diagrams .
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" infra-diagrams      # writes the three PNGs
```

The flow diagrams (app delivery, infrastructure delivery, secrets) are Mermaid blocks in the repository README;
GitHub renders them directly.
