# Running the `claude_code` package

## Prerequisites

- Docker running
- `claude` CLI installed on the host (`npm i -g @anthropic-ai/claude-code`)

## Steps

1. Generate a long-lived OAuth token on the host:
   ```bash
   claude setup-token
   ```

2. Export it (paste the token from step 1):
   ```bash
   export CLAUDE_CODE_OAUTH_TOKEN=<token>
   ```

3. Start an iex session in this repo:
   ```bash
   iex -S mix
   ```

4. Prepare the container:
   ```elixir
   {:ok, session} = Dockd.prepare_package("claude_code")
   ```

5. Ask claude something:
   ```elixir
   Dockd.Claude.ask(session, "ping")
   ```

To clean up: `Dockd.destroy(session)`.
