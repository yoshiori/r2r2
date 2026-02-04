require "gemini-ai"

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
  end

  def chat(text)
    messages = []
    contents = @history << { role: "user", parts: { text: text } }
    response = gemini.generate_content({
                                         contents: contents,
                                         system_instruction: { parts: { text: PROMPT } }
                                       })
    response["candidates"].each do |candidate|
      candidate.dig("content", "parts").each do |part|
        messages << part["text"]
        @history << { role: "model", parts: { text: part["text"] } }
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
