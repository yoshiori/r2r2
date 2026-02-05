require "gemini-ai"

require_relative "tools/read_file"
require_relative "tools/exec_command"

class GeminiClient
  # https://gist.github.com/iinm/892b10427ca71bbd9f83707b9b95c181#file-agent-mjs-L20-L32
  PROMPT = "
  You are an interactive CLI agent specializing in software engineering tasks.

  # Core Behavior
  - Proactively use tools to gather information and solve problems.
  - Do not ask for confirmation at every step. Make decisions autonomously.
  - Use exec_command for shell operations (ls, find, grep, etc.) and read_file to inspect file contents.
  - Execute multiple tool calls in parallel when feasible.
  - Only ask questions when critical information is genuinely missing.

  # Tone
  - Be concise and direct. Avoid conversational filler.
  - Focus on action, not explanation.

  # Workflow for Tasks
  1. **Understand**: Use tools to explore the codebase and gather context.
  2. **Plan**: Form a brief plan internally.
  3. **Implement**: Execute using available tools.
  4. **Verify**: Confirm the result if applicable.

  # User Interactions
  - Respond in the same language the user uses.
  - File paths are relative to the current working directory.
  ".strip

  TOOLS = [
    ReadFile,
    ExecCommand
  ].freeze

  def initialize(api_key)
    @api_key = api_key
    @history = []
    @tools = TOOLS.to_h { |tool| [tool.name, tool.new] }
    @function_declarations = {
      function_declarations: TOOLS.map(&:definition)
    }
  end

  def chat(text, &block)
    @history << { role: "user", parts: { text: text } }
    generate(&block)
  end

  private

  def generate(&block)
    response = gemini.generate_content({
                                         contents: @history,
                                         tools: @function_declarations,
                                         system_instruction: { parts: { text: PROMPT } }
                                       })
    response["candidates"].each do |candidate|
      parts = candidate.dig("content", "parts")
      @history << { role: "model", parts: parts }
      process_parts(parts, &block)
    end
  rescue Faraday::TooManyRequestsError
    puts "\e[2m[Rate limit hit, retrying in 5s...]\e[0m"
    sleep 5
    retry
  end

  def process_parts(parts, &block)
    function_response = []
    parts.each do |part|
      if part["functionCall"]
        function_response << execute_function(part["functionCall"])
      else
        yield part["text"]
      end
    end
    return if function_response.empty?

    @history << { role: "user", parts: function_response }
    generate(&block)
  end

  def execute_function(function_call)
    name = function_call["name"]
    args = function_call["args"]
    puts "\e[2m[#{name}] #{args}\e[0m"
    result = @tools[name].execute(**args.transform_keys(&:to_sym))
    { functionResponse: { name: name, response: { result: result } } }
  end

  def gemini
    @gemini ||= Gemini.new(
      credentials: {
        service: "generative-language-api",
        api_key: @api_key,
        version: "v1beta"
      },
      options: { model: "gemini-2.0-flash" }
    )
  end
end
