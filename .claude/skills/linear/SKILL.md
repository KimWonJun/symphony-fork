---
name: linear
description: Query and mutate Linear via its GraphQL API using curl and the LINEAR_API_KEY environment variable.
---

# Linear GraphQL

## Prerequisite

`LINEAR_API_KEY` is exported in this session's environment (inherited from the
Symphony orchestrator). There is no `linear_graphql` tool in the Claude
adapter — use `curl` directly.

## Primary usage

```bash
curl -s https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d @- <<'JSON'
{
  "query": "query Issue($id: String!) { issue(id: $id) { id identifier title description state { id name type } } }",
  "variables": {"id": "MT-123"}
}
JSON
```

Rules:

- Always pass GraphQL variables via the `variables` object; never interpolate
  values into the query string.
- Check the response for a top-level `errors` array before trusting `data`.
- Mutations (comments, state transitions) use the same shape with a
  `mutation` document.

## Query team workflow states for an issue

```bash
curl -s https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d @- <<'JSON'
{
  "query": "query IssueStates($id: String!) { issue(id: $id) { team { states { nodes { id name type } } } } }",
  "variables": {"id": "MT-123"}
}
JSON
```

## Discovering unfamiliar operations

Run a scoped introspection query, or consult
https://developers.linear.app/docs/graphql/working-with-the-graphql-api.
