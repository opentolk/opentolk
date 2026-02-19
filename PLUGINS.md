# OpenTolk Plugin Development Guide

OpenTolk plugins extend what happens after you speak. When you dictate text, OpenTolk transcribes it, then checks if any plugin should handle it. Plugins can translate, summarize, search the web, run scripts, call APIs, or use AI to transform your text — all triggered by voice.

## Quick Start

A plugin is a single JSON file. Save this as `~/.opentolk/plugins/hello.tolkplugin`:

```json
{
  "id": "com.example.hello",
  "name": "Hello",
  "version": "1.0.0",
  "description": "Responds with a greeting",
  "trigger": { "type": "keyword", "keywords": ["hello"] },
  "execution": { "type": "ai", "system_prompt": "Respond with a friendly greeting. Be brief." },
  "output": { "mode": "paste" }
}
```

That's it. It hot-reloads instantly. Say "hello how are you" and the AI response gets pasted into your active app.

---

## Plugin Formats

### Single-File Plugin

A `.tolkplugin` file (JSON) placed directly in `~/.opentolk/plugins/`. The file itself is the manifest. Best for AI plugins and simple configurations.

```
~/.opentolk/plugins/translate.tolkplugin
```

### Directory Plugin

A `.tolkplugin` folder containing `manifest.json` and supporting files (scripts, icons, prompt files). Required when your plugin needs scripts or additional assets.

```
~/.opentolk/plugins/my-plugin.tolkplugin/
├── manifest.json
├── main.py
├── icon.png
└── prompts/
    └── system.txt
```

---

## Manifest Reference

Every plugin has a manifest — either the single file itself or `manifest.json` in a directory plugin.

### Top-Level Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique reverse-DNS identifier: `com.author.plugin-name` |
| `name` | string | Yes | Display name shown in the UI |
| `version` | string | Yes | Semver version: `1.0.0` |
| `description` | string | Yes | One-line description of what the plugin does |
| `author` | object | No | `{ "name": "Your Name", "url": "https://..." }` |
| `icon` | string | No | Path to icon file relative to plugin directory |
| `categories` | string[] | No | Tags: `["ai", "translation", "productivity"]` |
| `permissions` | string[] | No | Required permissions (shown to user on enable) |
| `min_app_version` | string | No | Minimum OpenTolk version required |
| `homepage` | string | No | URL to plugin homepage |
| `repository` | string | No | URL to source code |
| `license` | string | No | License identifier: `MIT`, `Apache-2.0`, etc. |
| `trigger` | object | Yes | When to activate this plugin |
| `execution` | object | Yes | What to do when triggered |
| `output` | object | No | How to deliver the result (default: paste) |
| `settings` | object[] | No | User-configurable settings |

### Permissions

Declare what your plugin needs. Users approve permissions when enabling the plugin.

| Permission | Description |
|------------|-------------|
| `network` | Make outbound HTTP requests |
| `filesystem` | Read/write files in the plugin data directory |
| `clipboard` | Read clipboard contents |
| `notifications` | Send system notifications |
| `ai` | Use AI models to process text |
| `microphone` | Access the microphone |

---

## Trigger Types

The trigger determines when your plugin activates based on what the user said.

### Keyword Trigger

Matches when the transcribed text contains specific words.

```json
{
  "trigger": {
    "type": "keyword",
    "keywords": ["translate", "translation"],
    "position": "start",
    "strip_trigger": true
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `keywords` | string[] | required | Words to match (case-insensitive) |
| `position` | string | `"start"` | Where to look: `"start"`, `"end"`, `"anywhere"` |
| `strip_trigger` | bool | `false` | Remove the keyword from input before passing to execution |

**Priority:** 10 (highest). If multiple keyword plugins match, the longest keyword wins.

**Examples:**
- User says: "translate hello world" → keyword "translate" matches at start
- With `strip_trigger: true`, the plugin receives input: "hello world"
- With `strip_trigger: false`, the plugin receives input: "translate hello world"

### Regex Trigger

Matches using a regular expression pattern.

```json
{
  "trigger": {
    "type": "regex",
    "pattern": "^(remind me|set reminder)\\b",
    "strip_trigger": true
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `pattern` | string | required | Regular expression (case-insensitive) |
| `strip_trigger` | bool | `false` | Remove the matched portion from input |

**Priority:** 5.

### Intent Trigger

Uses AI classification to match based on meaning, not exact words. Requires the user to have an AI API key configured.

```json
{
  "trigger": {
    "type": "intent",
    "intents": ["check weather", "weather forecast", "temperature"],
    "examples": [
      "what's the weather like",
      "is it going to rain today",
      "how cold is it outside"
    ]
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `intents` | string[] | required | Short descriptions of what this plugin handles |
| `examples` | string[] | No | Example phrases that should trigger this plugin |

**Priority:** 3. Intent classification only runs when no keyword or regex plugin matches. It requires an AI API call, so there's a ~200ms latency cost.

### Catch-All Trigger

Matches everything. Use for plugins that should process all text that no other plugin handles.

```json
{
  "trigger": { "type": "catch_all" }
}
```

**Priority:** 0 (lowest). Only one catch-all plugin should be enabled at a time.

---

## Execution Types

### AI Execution

The simplest and most powerful type. Sends the user's text to an AI model with your system prompt. No code required.

**Requires:** User must have an OpenAI or Anthropic API key configured in Settings.

#### Minimal AI Plugin

```json
{
  "id": "com.example.eli5",
  "name": "Explain Like I'm 5",
  "version": "1.0.0",
  "description": "Simplifies complex text into plain language",
  "trigger": { "type": "keyword", "keywords": ["explain", "eli5"], "position": "start", "strip_trigger": true },
  "execution": { "type": "ai", "system_prompt": "Explain the following as if talking to a 5-year-old. Be concise and clear." },
  "output": { "mode": "paste" }
}
```

#### AI with Settings (User-Configurable)

```json
{
  "id": "com.example.translate",
  "name": "Translate",
  "version": "1.0.0",
  "description": "Translates text to your chosen language",
  "permissions": ["ai"],
  "trigger": { "type": "keyword", "keywords": ["translate"], "position": "start", "strip_trigger": true },
  "execution": {
    "type": "ai",
    "system_prompt": "Translate the following text to {{settings.target_language}}. Output only the translation, nothing else.",
    "temperature": 0.3
  },
  "output": { "mode": "paste" },
  "settings": [
    {
      "key": "target_language",
      "label": "Target Language",
      "type": "select",
      "options": ["Spanish", "French", "German", "Japanese", "Norwegian", "Chinese"],
      "default": "Norwegian"
    }
  ]
}
```

The `{{settings.target_language}}` template is replaced with the user's chosen value at runtime.

#### Conversational AI Plugin (Multi-Turn with Streaming)

```json
{
  "id": "com.example.assistant",
  "name": "AI Assistant",
  "version": "1.0.0",
  "description": "Ask anything. Remembers conversation context for 10 minutes.",
  "permissions": ["ai"],
  "trigger": { "type": "keyword", "keywords": ["hey", "ask"], "position": "start", "strip_trigger": true },
  "execution": {
    "type": "ai",
    "system_prompt": "You are a helpful, concise assistant. Answer questions directly.",
    "conversational": true,
    "streaming": true
  },
  "output": { "mode": "reply", "format": "markdown" }
}
```

This opens a floating chat panel where the user can see the AI response stream in real-time and type follow-up messages. Conversation history is maintained for 10 minutes.

#### AI with External System Prompt File

For long or complex system prompts, store them in a separate file:

```
my-plugin.tolkplugin/
├── manifest.json
└── prompts/
    └── system.txt
```

```json
{
  "execution": {
    "type": "ai",
    "system_prompt_file": "prompts/system.txt",
    "temperature": 0.7
  }
}
```

#### AI Config Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `system_prompt` | string | — | The system prompt (supports `{{input}}` and `{{settings.*}}` templates) |
| `system_prompt_file` | string | — | Path to a text file containing the system prompt (relative to plugin dir) |
| `model` | string | provider default | Model name. For OpenAI: `"gpt-4o"`, `"gpt-4o-mini"`. For Anthropic: `"claude-sonnet-4-20250514"` |
| `temperature` | number | provider default | 0.0 = deterministic, 1.0 = creative |
| `max_tokens` | int | provider default | Maximum response length in tokens |
| `streaming` | bool | `false` | Stream the response token-by-token (requires `"mode": "reply"` output) |
| `conversational` | bool | `false` | Enable multi-turn conversation (remembers context for 10 minutes) |
| `tools` | object[] | — | Tools the AI can call during conversation (see Tools section) |

Either `system_prompt` or `system_prompt_file` must be provided.

#### AI with Tools

AI plugins can use tools — functions the AI can call during its response.

```json
{
  "id": "com.example.researcher",
  "name": "Research Agent",
  "version": "1.0.0",
  "description": "Researches topics using web search",
  "permissions": ["ai", "network"],
  "trigger": { "type": "keyword", "keywords": ["research"], "position": "start", "strip_trigger": true },
  "execution": {
    "type": "ai",
    "system_prompt": "You are a research assistant. Use web_search to find information. Provide comprehensive answers with sources.",
    "conversational": true,
    "streaming": true,
    "tools": [
      { "name": "web_search", "type": "builtin" },
      { "name": "read_clipboard", "type": "builtin" }
    ]
  },
  "output": { "mode": "reply", "format": "markdown" }
}
```

**Builtin tools** (provided by OpenTolk):

| Tool | Description |
|------|-------------|
| `web_search` | Search the web using DuckDuckGo |
| `read_clipboard` | Read the current clipboard contents |
| `paste` | Paste text into the active application |
| `run_plugin` | Run another installed plugin (specify `plugin_id` in `config`) |

**Script tools** (provided by your plugin):

```json
{
  "tools": [
    {
      "name": "lookup_term",
      "type": "script",
      "command": "tools/lookup.sh",
      "description": "Looks up a term in the glossary",
      "parameters": {
        "type": "object",
        "properties": {
          "term": { "type": "string", "description": "The term to look up" }
        }
      }
    }
  ]
}
```

Script tools receive arguments as JSON on stdin and environment variable `OPENTOLK_TOOL_ARGS`. Plugin settings are available as `OPENTOLK_SETTINGS_*` environment variables (e.g., a setting with key `api_key` becomes `OPENTOLK_SETTINGS_API_KEY`). They return the result on stdout.

---

### Script Execution

Runs a local script. Supports bash, Python, Node.js, Ruby, and Swift.

#### Directory Plugin with Script

```
uppercase.tolkplugin/
├── manifest.json
└── main.sh
```

`manifest.json`:
```json
{
  "id": "com.example.uppercase",
  "name": "Uppercase",
  "version": "1.0.0",
  "description": "Converts text to uppercase",
  "trigger": { "type": "keyword", "keywords": ["uppercase", "caps"], "position": "start", "strip_trigger": true },
  "execution": { "type": "script", "command": "main.sh" },
  "output": { "mode": "paste" }
}
```

`main.sh`:
```bash
#!/bin/bash
echo "$OPENTOLK_INPUT" | tr '[:lower:]' '[:upper:]'
```

#### Python Script Plugin

```
word-count.tolkplugin/
├── manifest.json
└── count.py
```

`manifest.json`:
```json
{
  "id": "com.example.wordcount",
  "name": "Word Count",
  "version": "1.0.0",
  "description": "Counts words in your text",
  "trigger": { "type": "keyword", "keywords": ["count words"], "position": "start", "strip_trigger": true },
  "execution": { "type": "script", "command": "count.py", "interpreter": "python3" },
  "output": { "mode": "notify" }
}
```

`count.py`:
```python
import os
text = os.environ.get("OPENTOLK_INPUT", "")
words = len(text.split())
print(f"{words} words")
```

#### Inline Script (Single-File, No External Script Needed)

For short scripts, embed them directly in the manifest:

```json
{
  "id": "com.example.reverse",
  "name": "Reverse Text",
  "version": "1.0.0",
  "description": "Reverses the input text",
  "trigger": { "type": "keyword", "keywords": ["reverse"], "position": "start", "strip_trigger": true },
  "execution": {
    "type": "script",
    "inline": "echo \"$OPENTOLK_INPUT\" | rev",
    "interpreter": "bash"
  },
  "output": { "mode": "paste" }
}
```

#### Script Environment Variables

Every script receives these environment variables:

| Variable | Description |
|----------|-------------|
| `OPENTOLK_INPUT` | The text after trigger stripping |
| `OPENTOLK_RAW_INPUT` | The original transcribed text |
| `OPENTOLK_TRIGGER` | The matched trigger word |
| `OPENTOLK_PLUGIN_DIR` | Absolute path to the plugin directory |
| `OPENTOLK_DATA_DIR` | Writable data directory for this plugin (`~/.opentolk/plugin-data/{id}/`) |
| `OPENTOLK_SETTINGS_*` | Each setting as `OPENTOLK_SETTINGS_KEY` (uppercased key) |

#### Script Output Formats

Scripts return results via stdout. Three formats are supported:

**Plain text** (default):
```
Hello world
```

**JSON** (override output mode):
```json
{"text": "Hello world", "output": "notify"}
```

**Directive prefix** (override output mode):
```
@output:speak
Hello world
```

#### Script Config Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `command` | string | — | Path to script file relative to plugin directory |
| `inline` | string | — | Inline script content (for single-file plugins) |
| `interpreter` | string | auto-detect | `"bash"`, `"python3"`, `"node"`, `"ruby"`, `"swift"` |
| `timeout` | int | `30` | Maximum execution time in seconds |

Either `command` or `inline` must be provided.

---

### HTTP Execution

Makes an HTTP request and uses the response as the plugin result.

#### Simple API Call

```json
{
  "id": "com.example.define",
  "name": "Define Word",
  "version": "1.0.0",
  "description": "Looks up word definitions",
  "permissions": ["network"],
  "trigger": { "type": "keyword", "keywords": ["define"], "position": "start", "strip_trigger": true },
  "execution": {
    "type": "http",
    "url": "https://api.dictionaryapi.dev/api/v2/entries/en/{{input}}",
    "method": "GET",
    "response_json_path": "[0].meanings[0].definitions[0].definition"
  },
  "output": { "mode": "notify" }
}
```

#### POST Request with Headers and Body

```json
{
  "id": "com.example.shorten",
  "name": "Shorten URL",
  "version": "1.0.0",
  "description": "Shortens URLs using a URL shortener API",
  "permissions": ["network"],
  "trigger": { "type": "keyword", "keywords": ["shorten"], "position": "start", "strip_trigger": true },
  "execution": {
    "type": "http",
    "url": "https://api.short.io/links",
    "method": "POST",
    "headers": {
      "Content-Type": "application/json",
      "Authorization": "{{settings.api_key}}"
    },
    "body": {
      "originalURL": "{{input}}",
      "domain": "short.io"
    },
    "response_json_path": "shortURL"
  },
  "output": { "mode": "clipboard" },
  "settings": [
    { "key": "api_key", "label": "API Key", "type": "secret", "required": true }
  ]
}
```

#### Template Variables

Use `{{input}}` and `{{settings.key}}` in the URL, headers, and body. They are replaced with actual values at runtime.

#### HTTP Config Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `url` | string | required | Request URL (supports templates) |
| `method` | string | `"POST"` | HTTP method: `GET`, `POST`, `PUT`, `DELETE`, `PATCH` |
| `headers` | object | — | HTTP headers (values support templates) |
| `body` | any | — | Request body (JSON, values support templates) |
| `response_json_path` | string | — | Extract a value from JSON response using dot notation and array indexing, e.g. `"data.items[0].text"` |
| `timeout` | int | `30` | Request timeout in seconds |

---

### Shortcut Execution

Runs a macOS Shortcut by name. Input is passed via stdin.

```json
{
  "id": "com.example.summarize-shortcut",
  "name": "Summarize (Shortcut)",
  "version": "1.0.0",
  "description": "Runs the 'Summarize Text' macOS Shortcut",
  "trigger": { "type": "keyword", "keywords": ["summarize"], "position": "start", "strip_trigger": true },
  "execution": {
    "type": "shortcut",
    "shortcut_name": "Summarize Text",
    "timeout": 60
  },
  "output": { "mode": "paste" }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `shortcut_name` | string | required | Name of the macOS Shortcut to run |
| `timeout` | int | `30` | Maximum execution time in seconds |

---

### Pipeline Execution

Chains multiple plugins together. Output of each step becomes input for the next.

```json
{
  "id": "com.example.proofread",
  "name": "Proofread & Translate",
  "version": "1.0.0",
  "description": "Fixes grammar, then translates to Norwegian",
  "trigger": { "type": "keyword", "keywords": ["proofread"], "position": "start", "strip_trigger": true },
  "execution": {
    "type": "pipeline",
    "steps": [
      { "plugin": "com.example.grammar-fix" },
      { "plugin": "com.example.translate" }
    ]
  },
  "output": { "mode": "paste" }
}
```

Each step references another installed plugin by its `id`. The plugins in the pipeline don't need to be enabled — they just need to be installed.

| Field | Type | Description |
|-------|------|-------------|
| `steps` | object[] | Ordered list of plugins to run |
| `steps[].plugin` | string | Plugin ID to invoke |
| `steps[].settings_override` | object | Override settings for this step (optional) |

---

## Output Modes

The output determines what happens with the plugin's result.

```json
{
  "output": {
    "mode": "paste",
    "fallback": "clipboard",
    "also": ["clipboard"],
    "format": "markdown"
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `mode` | string | `"paste"` | Primary output mode |
| `fallback` | string | — | Fallback mode if primary fails |
| `also` | string[] | — | Additional side-effect modes to run after primary |
| `format` | string | `"plain"` | Text format: `"plain"` or `"markdown"` |

### Available Modes

| Mode | Description |
|------|-------------|
| `paste` | Pastes the result text into the currently focused application |
| `clipboard` | Copies result to the clipboard |
| `notify` | Shows a system notification with the result |
| `speak` | Reads the result aloud using text-to-speech |
| `panel` | Shows the result in a floating window with copy button |
| `store` | Saves to history only (no user-visible output) |
| `silent` | Does nothing (useful for side-effect-only plugins) |
| `reply` | Opens a conversation panel with the result (best for conversational AI plugins) |

### Multi-Action Output

Use `also` to perform multiple actions:

```json
{
  "output": {
    "mode": "paste",
    "also": ["clipboard", "notify"]
  }
}
```

This pastes the result AND copies it to the clipboard AND shows a notification.

---

## Settings

Settings let users configure your plugin without editing JSON. They appear in the plugin settings sheet in the UI.

```json
{
  "settings": [
    {
      "key": "api_key",
      "label": "API Key",
      "type": "secret",
      "required": true,
      "placeholder": "sk-..."
    },
    {
      "key": "language",
      "label": "Language",
      "type": "select",
      "options": ["English", "Spanish", "French", "German"],
      "default": "English"
    },
    {
      "key": "verbose",
      "label": "Verbose Output",
      "type": "bool",
      "default": false
    },
    {
      "key": "max_words",
      "label": "Max Words",
      "type": "number",
      "default": 100,
      "placeholder": "100"
    },
    {
      "key": "custom_prompt",
      "label": "Custom Instructions",
      "type": "text",
      "placeholder": "Additional instructions for the AI..."
    }
  ]
}
```

### Setting Types

| Type | UI Element | Description |
|------|-----------|-------------|
| `string` | Text field | Single-line text input |
| `secret` | Secure field | Hidden text (stored in macOS Keychain, not on disk) |
| `select` | Dropdown | Choose from a list of `options` |
| `bool` | Toggle switch | On/off |
| `text` | Text area | Multi-line text input |
| `number` | Text field | Numeric input |

### Using Settings in Execution

Reference settings with `{{settings.key}}` in:
- AI system prompts
- HTTP URLs, headers, and body
- Available as `OPENTOLK_SETTINGS_KEY` environment variables in scripts

---

## Complete Examples

### 1. Grammar Fixer (AI, One-Shot)

```json
{
  "id": "com.example.grammar",
  "name": "Fix Grammar",
  "version": "1.0.0",
  "description": "Fixes grammar and spelling mistakes",
  "permissions": ["ai"],
  "trigger": { "type": "keyword", "keywords": ["fix", "grammar"], "position": "start", "strip_trigger": true },
  "execution": {
    "type": "ai",
    "system_prompt": "Fix any grammar, spelling, and punctuation errors in the following text. Output only the corrected text, preserving the original meaning and tone. Do not add explanations.",
    "temperature": 0.2
  },
  "output": { "mode": "paste" }
}
```

### 2. Email Composer (AI, with Settings)

```json
{
  "id": "com.example.email",
  "name": "Compose Email",
  "version": "1.0.0",
  "description": "Turns rough notes into professional emails",
  "permissions": ["ai"],
  "trigger": { "type": "keyword", "keywords": ["email", "compose"], "position": "start", "strip_trigger": true },
  "execution": {
    "type": "ai",
    "system_prompt": "Convert the following rough notes into a professional email. Use a {{settings.tone}} tone. Sign off as {{settings.name}}. Output only the email text.",
    "temperature": 0.5
  },
  "output": { "mode": "paste" },
  "settings": [
    { "key": "tone", "label": "Tone", "type": "select", "options": ["formal", "friendly", "casual"], "default": "friendly" },
    { "key": "name", "label": "Your Name", "type": "string", "placeholder": "John" }
  ]
}
```

### 3. Code Explainer (AI, Streaming with Markdown)

```json
{
  "id": "com.example.code-explain",
  "name": "Explain Code",
  "version": "1.0.0",
  "description": "Reads your clipboard and explains the code",
  "permissions": ["ai", "clipboard"],
  "trigger": { "type": "keyword", "keywords": ["explain code", "what does this code do"], "position": "start" },
  "execution": {
    "type": "ai",
    "system_prompt": "The user will describe code or ask about code. If their message is vague, use the read_clipboard tool to get the code they're looking at. Explain clearly with examples.",
    "conversational": true,
    "streaming": true,
    "tools": [
      { "name": "read_clipboard", "type": "builtin" }
    ]
  },
  "output": { "mode": "reply", "format": "markdown" }
}
```

### 4. Timestamp Logger (Script, Inline)

```json
{
  "id": "com.example.timestamp",
  "name": "Timestamp",
  "version": "1.0.0",
  "description": "Prepends current timestamp to your text",
  "trigger": { "type": "keyword", "keywords": ["timestamp", "ts"], "position": "start", "strip_trigger": true },
  "execution": {
    "type": "script",
    "inline": "echo \"[$(date '+%Y-%m-%d %H:%M')] $OPENTOLK_INPUT\""
  },
  "output": { "mode": "paste" }
}
```

### 5. Notion Quick Note (HTTP)

```json
{
  "id": "com.example.notion-note",
  "name": "Quick Note to Notion",
  "version": "1.0.0",
  "description": "Saves dictated text as a Notion page",
  "permissions": ["network"],
  "trigger": { "type": "keyword", "keywords": ["note", "save note"], "position": "start", "strip_trigger": true },
  "execution": {
    "type": "http",
    "url": "https://api.notion.com/v1/pages",
    "method": "POST",
    "headers": {
      "Authorization": "Bearer {{settings.notion_key}}",
      "Content-Type": "application/json",
      "Notion-Version": "2022-06-28"
    },
    "body": {
      "parent": { "database_id": "{{settings.database_id}}" },
      "properties": {
        "Name": { "title": [{ "text": { "content": "{{input}}" } }] }
      }
    }
  },
  "output": { "mode": "notify" },
  "settings": [
    { "key": "notion_key", "label": "Notion API Key", "type": "secret", "required": true },
    { "key": "database_id", "label": "Database ID", "type": "string", "required": true }
  ]
}
```

### 6. Weather via Intent (Natural Language Trigger)

```json
{
  "id": "com.example.weather",
  "name": "Weather",
  "version": "1.0.0",
  "description": "Answers weather questions",
  "permissions": ["ai", "network"],
  "trigger": {
    "type": "intent",
    "intents": ["check weather", "weather forecast", "temperature"],
    "examples": ["what's the weather like", "is it going to rain", "how cold is it outside", "do I need an umbrella"]
  },
  "execution": {
    "type": "ai",
    "system_prompt": "You answer weather questions. Use web_search to find current weather data. Be concise.",
    "tools": [{ "name": "web_search", "type": "builtin" }]
  },
  "output": { "mode": "reply" }
}
```

### 7. Multi-Step Pipeline

```json
{
  "id": "com.example.polish",
  "name": "Polish Text",
  "version": "1.0.0",
  "description": "Fixes grammar, then improves clarity",
  "trigger": { "type": "keyword", "keywords": ["polish"], "position": "start", "strip_trigger": true },
  "execution": {
    "type": "pipeline",
    "steps": [
      { "plugin": "com.example.grammar" },
      { "plugin": "com.example.rephrase" }
    ]
  },
  "output": { "mode": "paste" }
}
```

### 8. Catch-All Assistant

```json
{
  "id": "com.example.catch-all",
  "name": "Default Assistant",
  "version": "1.0.0",
  "description": "Handles any text that no other plugin matches",
  "permissions": ["ai"],
  "trigger": { "type": "catch_all" },
  "execution": {
    "type": "ai",
    "system_prompt": "You are a helpful assistant. The user dictated the following text. Determine what they need and help them. If they seem to just be dictating text (not asking a question), output their text exactly as-is with fixed grammar.",
    "temperature": 0.3
  },
  "output": { "mode": "paste" }
}
```

### 9. macOS Shortcut Integration

```json
{
  "id": "com.example.focus-mode",
  "name": "Toggle Focus",
  "version": "1.0.0",
  "description": "Toggles Do Not Disturb via a macOS Shortcut",
  "trigger": { "type": "keyword", "keywords": ["focus mode", "do not disturb"], "position": "start" },
  "execution": { "type": "shortcut", "shortcut_name": "Toggle Focus Mode" },
  "output": { "mode": "notify" }
}
```

### 10. Plugin That Calls Another Plugin (Tool Use)

```json
{
  "id": "com.example.smart-reply",
  "name": "Smart Reply",
  "version": "1.0.0",
  "description": "Reads clipboard, drafts a reply, and translates if needed",
  "permissions": ["ai", "clipboard"],
  "trigger": { "type": "keyword", "keywords": ["reply"], "position": "start", "strip_trigger": true },
  "execution": {
    "type": "ai",
    "system_prompt": "You help draft replies. First read_clipboard to see what message the user received. Then draft a concise reply based on the user's instructions. If the message is in a foreign language, use run_plugin to translate your reply.",
    "conversational": true,
    "streaming": true,
    "tools": [
      { "name": "read_clipboard", "type": "builtin" },
      { "name": "run_plugin", "type": "builtin", "config": { "plugin_id": "com.example.translate" } }
    ]
  },
  "output": { "mode": "reply", "format": "markdown" }
}
```

---

## Plugin Data Directory

Each plugin gets a writable data directory at `~/.opentolk/plugin-data/{plugin-id}/`. Use this to store state, caches, or logs.

- Scripts access it via the `OPENTOLK_DATA_DIR` environment variable
- The directory is created automatically on first access
- It is deleted when the plugin is uninstalled

---

## Hot Reload

OpenTolk watches `~/.opentolk/plugins/` for changes. When you add, edit, or remove a `.tolkplugin` file or folder, plugins are reloaded automatically within ~500ms. No need to restart the app.

---

## Installation Methods

1. **Manual:** Drop `.tolkplugin` files into `~/.opentolk/plugins/`
2. **URL scheme:** `opentolk://install-plugin?url=https://example.com/plugin.zip`
3. **Browse tab:** Search and install from the community plugins directory
4. **GitHub:** The installer resolves GitHub repo URLs to their latest release automatically

## Publishing to the Browse Tab

To make your plugin discoverable in the Browse tab, it must be listed in the [community-plugins](https://github.com/opentolk/community-plugins) repository:

1. Add your `.tolkplugin` file (or `.tolkplugin.zip` for directory plugins) to the `plugins/` folder
2. Add an entry to `plugins.json` with your plugin's metadata (id, name, version, description, author, categories, download URL)
3. Submit a pull request

See [`CONTRIBUTING.md`](https://github.com/opentolk/community-plugins/blob/main/CONTRIBUTING.md) in the community-plugins repo for the full process and `plugins.json` format.

---

## Routing Priority

When multiple plugins could match the same text, OpenTolk uses this priority order:

1. **Keyword** (priority 10) — instant, deterministic
2. **Regex** (priority 5) — instant, deterministic
3. **Intent** (priority 3) — AI classification, ~200ms latency
4. **Catch-all** (priority 0) — matches everything

Within the same priority level, the longest matching trigger wins. Keyword and regex matching are always tried first. Intent classification only runs if no deterministic match is found.
