require "gemini-ai"

require_relative "tools/read_file"

class GeminiClient
  # https://gist.github.com/iinm/892b10427ca71bbd9f83707b9b95c181#file-agent-mjs-L20-L32
  PROMPT = "
  You are a problem solver.
  - Solve problems provided by users.
  - Clarify the essence of the problem by asking questions before proceeding.
  - Clarify the goal of problem solving and confirm it with the user before proceeding.
  - Divide the task into smaller parts, confirm the plan with the user, and then solve each part one by one.
  # User Interactions
  - Respond to users in the same language they use.
  - Users specify file paths relative to the current working directory.
  ".strip

  TOOLS = [
    ReadFile
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
