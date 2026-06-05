require "openai"
require "rainbow"
require "logger"
require "json"

require_relative "tools/read_file"
require_relative "tools/write_file"
require_relative "tools/exec_command"

class LlmClient
  PROMPT = <<~PROMPT
    You are R2D2, an interactive CLI agent for software engineering tasks.

    # When to use tools (read this first)
    Tools are for software engineering tasks, not for every message.

    - Greetings ("hi", "hello", "こんにちは"), small talk, thanks, and questions answerable from your own knowledge: reply in plain text. DO NOT call any tool.
    - A request to inspect, change, run, or reason about files/commands in this project: use the tools below.

    When in doubt, assume action and try a tool — the result will tell you more than asking the user would.

    # Top priorities (in order)
    1. IMPORTANT: Never call write_file on a path you have not read with read_file in this conversation. write_file replaces the ENTIRE file; unread content will be destroyed.
    2. Work the whole task autonomously. Plan, gather context, make changes, and verify in one turn. DO NOT pause to ask "should I proceed?", "shall I read this file?", or "do you want me to continue?" between steps — just do the next step.
    3. Ask the user ONLY when (a) the task is genuinely ambiguous in a way no tool can resolve, or (b) you are about to run a destructive command (see Safety). Otherwise: act.
    4. End every turn with a short final message to the user. That message ends the turn — do not keep calling tools after sending it.

    # Tools
    - read_file(path): returns the full contents of a file.
    - write_file(path, content): OVERWRITES the file at `path` with `content`. There is no partial edit; you must include everything you want to keep.
    - exec_command(command): runs a shell command. Use for `ls`, `tree`, `find`, `grep`, running tests, git, etc.

    Call independent tools in the same response to run them in parallel.

    # How to work a task
    1. Understand: use `exec_command` (e.g. `ls`, `tree -L 2`) and `read_file` to gather just enough context.
    2. Act: make the change with the right tool. Keep edits minimal and scoped to the request — do not refactor unrelated code.
    3. Verify: run tests or re-read the file to confirm the change is correct.
    4. Report: send one short final message summarizing what changed. Done.

    Skip steps you do not need. A pure question may need zero tool calls.

    # Editing files (CRITICAL)
    - read_file the target first, then write_file with the full new contents.
    - For a small edit, include the entire existing file plus your change.
    - Match the surrounding code's naming, indentation, and style. Read a neighboring file before introducing a new convention.

    # Errors
    - Read the error message before reacting. It usually names the cause directly (e.g. `uninitialized constant Foo::Bar` ⇒ the constant does not exist).
    - Do not retry the same command unchanged. Investigate with read_file or exec_command first, then try a different approach — do not ask the user how to recover from an error you can diagnose yourself.

    # Tests (only when the task involves writing or modifying tests)
    - read_file the source under test. Use the exact module, class, and method names you confirmed there — never guess.
    - read_file an existing test file to copy the project's test style and require setup.
    - Mock or stub every external dependency (HTTP, DB, filesystem outside the fixture). Tests must not make real network calls.

    # Safety
    - IMPORTANT: Before destructive commands (`rm`, `git reset --hard`, force-push, dropping data, overwriting unrelated files), ask the user to confirm. Non-destructive commands need no confirmation.

    # Output
    - Respond in the same language the user used.
    - Be concise and direct. No filler, no apologies, no restating the request.
    - File paths are relative to the current working directory.
  PROMPT

  TOKEN_LIMIT = 100_000
  RECENT_KEEP_COUNT = 10

  TOOLS = [
    ReadFile,
    WriteFile,
    ExecCommand
  ].freeze

  def initialize(api_key, uri_base, model)
    @api_key = api_key
    @model = model
    @uri_base = uri_base
    @history = []
    @tools = TOOLS.to_h { |tool| [tool.name, tool.new] }
    @tool_definitions = TOOLS.map(&:definition)
    @logger = Logger.new($stderr, level: ENV["R2D2_DEBUG"] ? Logger::DEBUG : Logger::INFO)
  end

  def chat(text, &block)
    @history << { "role" => "user", "content" => text }
    generate(&block)
  end

  private

  SPINNER_CHARS = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

  def with_spinner
    stop = false
    spinner = Thread.new do
      i = 0
      until stop
        print "\r#{Rainbow(SPINNER_CHARS[i % SPINNER_CHARS.size]).cyan} thinking..."
        i += 1
        sleep 0.1
      end
      print "\r\e[2K"
    end
    result = yield
    stop = true
    spinner.join
    result
  end

  def generate(&block)
    response = with_spinner do
      client.chat(
        parameters: {
          model: @model,
          messages: [{ "role" => "system", "content" => PROMPT }] + @history,
          tools: @tool_definitions
        }
      )
    end
    @logger.debug { JSON.pretty_generate(response) }

    prompt_tokens = response.dig("usage", "prompt_tokens") || 0
    compress_history! if prompt_tokens > TOKEN_LIMIT

    message = response.dig("choices", 0, "message")
    unless message
      @logger.error { "API error: No response received. Full response: #{response.inspect}" }
      yield "API error: No response received."
      return
    end

    @history << message
    process_message(message, &block)
  rescue Faraday::TooManyRequestsError
    puts Rainbow("[Rate limit hit, retrying in 5s...]").faint
    sleep 5
    retry
  end

  def process_message(message, &block)
    if message["tool_calls"]
      tool_results = message["tool_calls"].map { |tool_call| execute_function(tool_call) }
      @history.concat(tool_results)
      generate(&block)
    elsif message["content"]
      yield message["content"]
    end
  end

  def execute_function(tool_call)
    name = tool_call.dig("function", "name")
    args = JSON.parse(tool_call.dig("function", "arguments"))
    puts Rainbow("[#{name}] #{args}").faint
    begin
      result = @tools[name].execute(**args.transform_keys(&:to_sym))
    rescue StandardError => e
      result = "Error: #{e.message}"
    end
    @logger.debug { "Tool result: #{result}" }
    { "role" => "tool", "tool_call_id" => tool_call["id"], "content" => result.to_s }
  end

  SUMMARIZE_PROMPT = <<~PROMPT
    Below is a conversation history between an AI assistant and a user.
    Please summarize this conversation concisely.

    Include:
    - What the user requested
    - What actions were taken (file paths, commands executed, etc.)
    - What the results were
    - Current state of the work

    Exclude:
    - Full file contents (paths are sufficient)
    - Full command output (just the key results)
  PROMPT

  def compress_history!
    split_at = find_safe_split_index
    return if split_at <= 0

    old_history = @history[0...split_at]
    recent_history = @history[split_at..]

    summary_response = with_spinner do
      client.chat(
        parameters: {
          model: @model,
          messages: [{ "role" => "system", "content" => PROMPT }] +
                    old_history +
                    [{ "role" => "user", "content" => SUMMARIZE_PROMPT }]
        }
      )
    end

    summary_text = summary_response.dig("choices", 0, "message", "content")

    if summary_text.nil? || summary_text.empty?
      @logger.warn("History compression failed: summary was empty. Will retry on next turn.")
      return
    end

    @history = [
      { "role" => "user", "content" => "Summary of the conversation so far:\n#{summary_text}" },
      { "role" => "assistant", "content" => "Understood. Let's continue." }
    ] + recent_history

    puts Rainbow("History compressed: #{old_history.size} messages summarized").faint
  end

  def find_safe_split_index
    from = @history.size - RECENT_KEEP_COUNT

    index = @history[0...from].rindex do |msg|
      msg["role"] == "assistant" && !msg["tool_calls"]
    end

    index ? index + 1 : 0
  end

  def client
    @client ||= OpenAI::Client.new(
      access_token: @api_key,
      uri_base: @uri_base
    )
  end
end
