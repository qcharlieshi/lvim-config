# Codebase / multi-repo architecture views — landscape (2026-11-10)

Goal: high-level views of how a codebase (or a set of repos, e.g. `~/dev/lilt/*`) is put together, to make changes with confidence.

## Four families of tools

| Family | Examples | Built from | Good at | Weak at |
|---|---|---|---|---|
| **Code knowledge graph** (symbol-level) | graphify, code-cortex-mcp, code-graph-mcp, GitCortex, codegraph | tree-sitter AST → calls/imports/inherits | "who calls X", blast radius, god nodes, communities/clusters | Too fine-grained for "what are the services"; hairball HTML; goes stale |
| **Service / architecture map** (component-level) | ridge (MCP), Kuuhaku, MeshGraph (VS Code), arch-viewer | Static analysis + heuristics for HTTP routes, gRPC, queues, DBs, docker-compose/k8s | Services ↔ endpoints ↔ queues ↔ datastores across repos; C4/Mermaid/D2 export; drift between refs | Heuristic edges (HTTP client → route matching); framework coverage varies (Spring often missing) |
| **LLM-written wiki** | DeepWiki / deepwiki-open, RepoWiki, llmwiki, deepforge, CodeWiki | LLM reads ranked files → prose + Mermaid | Narrative "what is this and how does it flow"; reading order; onboarding | Can hallucinate; costs tokens; must be re-generated; edges not verifiable |
| **Agent-authored, repo-committed diagrams** | uigraph skill, llmwiki `output_mode: local` | Coding agent writes Mermaid/OpenAPI/.yaml into repo | Diagrams diffable in PRs; you choose which views exist | Only as good as the prompt; manual refresh |

## graphify specifically
- `uv tool install graphifyy` (double-y). CLI `graphify` + `graphify-mcp`. Apache-2.0.
- `graphify extract . --code-only && graphify cluster-only . --no-label` → `graphify-out/{graph.json, GRAPH_REPORT.md, graph.html}`. Fully local with `--code-only`; without it, an LLM semantic pass over docs.
- Commands: `god-nodes`, `explain <node>`, `path A B`, `query "..."`, `affected` (blast radius), `update` (incremental).
- Leiden communities = auto-detected subsystems. Edges tagged EXTRACTED / INFERRED / AMBIGUOUS.
- Hosted platform supports combined cross-repo graphs (up to 100 repos); OSS CLI is per-folder (can point at a parent dir).

### What people actually found (independent evals)
- **Agent token savings mostly don't materialize** with strong models: Machine Room (Opus 5.5, 16 runs) +~70k tokens/question, same correctness; Constantin (FastAPI, 11 Qs) +49% input, +9.5% cost. Agents still grep/read to verify.
- **Human-facing value is real**: `GRAPH_REPORT.md` (god nodes, communities), `affected`, `path`, `explain` — "install it for yourself, not to cut the agent's bill." Caught dead-but-live imports and stale notes.
- **`graph.html` silently skipped above 5,000 nodes** — any real repo hits this. Visualization at symbol level is a hairball.
- `query`/`explain` lost to `rg` in one eval and gave a confidently-wrong answer.
- Graph is a snapshot; must `update` after changes. Needs `.graphifyignore` for vendor/generated code.

Sources:
- https://github.com/Graphify-Labs/graphify · https://docs.graphify.com/cookbooks/onboard-to-a-codebase
- https://themachineroom.dev/v/graphify-measured/
- https://constantinsblog.eu/posts/graphify-llm-query-tool/
- https://praveenvijayan.substack.com/p/your-knowledge-graph-is-making-your
- https://www.kevinkinnett.com/posts/graphify-review-claude-code-knowledge-graph/
- https://github.com/robertphyatt/ironclaude/blob/main/docs/graphify-investigation.md
- https://github.com/olgasafonova/ridge · https://devhunt.org/tool/kuuhaku · https://github.com/uigraph-oss/uigraph
- https://github.com/he-yufeng/RepoWiki · https://github.com/emgiezet/llmwiki

## Already available locally (worth noting)
- **Backstage MCP** is configured (`get_component_architecture`, `list_components`, `trace_code_path`, `search_codebase`) — LILT's service catalog may already hold the component-level map.
- **Unblocked** — the "why" behind architecture (PRs, Slack, design docs). No structural graph.
- No `graphify`, `dot`, `d2`, or `mmdc` installed yet.

## Takeaways
1. "Architecture" at the level the user wants (services, data flow, boundaries) is **component-level**, not symbol-level. Symbol graphs (graphify) need clustering/collapsing to be readable.
2. Best results combine: deterministic graph for *verifiable edges* + LLM/human for *naming and narrative*.
3. Views must be cheap to regenerate or they rot.
