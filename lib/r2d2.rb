# frozen_string_literal: true

require "dotenv/load"
require "gemini-ai"

require_relative "r2d2/version"
require_relative "r2d2/gemini_client"

module R2d2
  class Error < StandardError; end

  def self.start(_args)
    client = GeminiClient.new(ENV["GEMINI_API_KEY"])
    puts "R2d2 is starting..."
    loop do
      print "\n > "
      input = gets.chomp
      break if input.downcase == "exit"

      messages = client.chat(input)
      messages.each do |message|
        puts "R2d2: #{message}"
      end
    end
    puts "--- End of Session ---\n"
  end
end
