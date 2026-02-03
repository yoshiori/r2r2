# frozen_string_literal: true

require "dotenv/load"
require "gemini-ai"

require_relative "r2d2/version"
require_relative "r2d2/GeminiClient"

module R2d2
  class Error < StandardError; end

  def self.start(_args)
    client = GeminiClient.new(ENV["GEMINI_API_KEY"])
    puts "R2d2 is starting..."
    loop do
      print "\nPlease enter your problem (or type 'exit' to quit): "
      input = gets.chomp

      puts "\n--- Problem Solving Session ---"
      puts "User Input: #{input}"

      messages = client.chat(input)
      messages.each do |message|
        puts "R2d2: #{message}"
      end
    end
    puts "--- End of Session ---\n"
  end
end
