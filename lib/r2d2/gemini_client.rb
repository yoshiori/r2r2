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

  def initialize(api_key)
    @api_key = api_key
    @history = []
    @tools = {
      function_declarations: [
        {
          name: "read_file",
          description: "Read the contents of a file at the given path. " \
               "Use this to understand code, gather context, or inspect files " \
               "before answering questions or making decisions.",
          parameters: {
            type: "object",
            properties: {
              path: {
                type: "string",
                description: "The relative file path from the current working directory"
              }
            },
            required: ["path"]
          }
        }
      ]
    }
  end

  def chat(text)
    @history << { role: "user", parts: { text: text } }
    generate
  end

  private

  def generate
    messages = []
    response = gemini.generate_content({
                                         contents: @history,
                                         tools: @tools,
                                         system_instruction: { parts: { text: PROMPT } }
                                       })
    response["candidates"].each do |candidate|
      parts = candidate.dig("content", "parts")
      @history << { role: "model", parts: parts }

      function_response = []
      parts.each do |part|
        if part["functionCall"]
          name = part["functionCall"]["name"]
          args = part["functionCall"]["args"]

          result = ReadFile.new.execute(args["path"])
          function_response << { functionResponse: { name: name, response: { result: result } } }
        else
          messages << part["text"]
        end
      end

      unless function_response.empty?
        @history << { role: "user", parts: function_response }
        messages.concat(generate)
      end
    end
    messages
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
