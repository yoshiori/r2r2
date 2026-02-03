# frozen_string_literal: true

require "dotenv/load"
require "gemini-ai"

require_relative "r2d2/version"

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

module R2d2
  class Error < StandardError; end

  def self.start(_args)
    puts "R2d2 is starting..."
    loop do
      print "\nPlease enter your problem (or type 'exit' to quit): "
      input = gets.chomp

      puts "\n--- Problem Solving Session ---"
      puts "User Input: #{input}"

      response = gemini.stream_generate_content({
                                                  contents: { role: "user", parts: { text: input } }
                                                })
      response.each do |message|
        message["candidates"].each do |candidate|
          candidate.dig("content", "parts").each do |part|
            puts "R2d2: #{part["text"]}"
          end
        end
      end
    end
    puts "--- End of Session ---\n"
  end

  def self.gemini
    @gemini ||= Gemini.new(
      credentials: {
        service: "generative-language-api",
        api_key: ENV["GEMINI_API_KEY"],
        version: "v1beta"
      },
      options: { model: "gemini-2.5-flash" }
    )
  end
end
