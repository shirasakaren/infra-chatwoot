# Architecture diagrams

PlantUML source for the diagrams referenced from the project README.

## Render locally

```bash
# Install PlantUML (one-time)
brew install plantuml          # macOS
# or: sudo apt install plantuml

# Render every diagram to SVG
plantuml -tsvg *.puml

# Or PNG, with a transparent background
plantuml -tpng -SbackgroundColor=transparent *.puml
```

## Render in a browser

Paste a `.puml` file's contents into <https://www.plantuml.com/plantuml/uml/>.

## Files

| File                     | What it shows                                            |
|--------------------------|----------------------------------------------------------|
| `architecture.puml`      | End-to-end component view of the deployed system         |
| `network-topology.puml`  | VPC layout: AZs, subnets, NATs, route tables             |
| `secrets-flow.puml`      | How app secrets reach pods without ever touching tfstate |
| `phases.puml`            | Deployment phases 0–8 with their validation gates        |
| `ha-model.puml`          | What survives each failure mode                          |

> [!NOTE]
> The project README embeds the same diagrams as Mermaid so they render
> natively on GitHub. The PlantUML sources here are kept in sync as the
> authoritative architecture documentation for higher-fidelity exports
> (PDF, SVG, slides, etc.).
