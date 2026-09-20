# frozen_string_literal: true

require "test_helper"
require "active_record"
require "jev/rails"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Base.logger = nil

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :jev_tickets, force: true do |t|
    t.string :subject
    t.text :body
    t.string :channel
    t.float :urgency
    t.json :urgency_jev
    t.string :intent
    t.json :intent_jev
    t.float :frustration
    t.json :frustration_jev
    t.timestamps
  end
end

module JevTestSupport
  QUESTIONS = {
    urgency: -> { Jev.noul("Does this need a human within the hour?") },
    intent: -> { Jev.choice("What is this about?", %w[billing technical sales]) },
    frustration: -> { Jev.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"]) }
  }.freeze

  def self.model(&block)
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "jev_tickets"
    end
    klass.class_eval(&block) if block
    klass
  end

  def self.answer(type, name)
    case type
    when :noul then { "type" => "noul", "noul" => 0.91 }
    when :choice
      { "type" => "choice", "choice" => "billing", "confidence" => 0.88,
        "probabilities" => { "billing" => 0.92, "technical" => 0.08, "sales" => 0.0 } }
    when :score
      { "type" => "score", "score" => 1.22, "confidence" => 0.67,
        "legend" => { "0" => "Calm", "1" => "Frustrated", "2" => "Very angry" },
        "probabilities" => { "0" => 0.0, "1" => 0.78, "2" => 0.22 } }
    end.merge("name" => name.to_s)
  end

  class RecordingClient
    attr_reader :calls

    def initialize(&responder)
      @calls = []
      @responder = responder
      @mutex = Mutex.new
    end

    def call(state:, questions:, model: nil)
      @mutex.synchronize { @calls << { state: state, questions: questions, model: model } }
      body = {
        "model" => "jev-test-1",
        "answers" => questions.to_h { |name, q| [name.to_s, answer_for(q, name, state)] },
        "usage" => { "input_tokens" => 10, "output_tokens" => 2 }
      }
      Jev::ResultSet.from_response(body, questions: questions, latency: 0.01)
    end

    def call_count
      @mutex.synchronize { @calls.size }
    end

    def reset!
      @mutex.synchronize { @calls.clear }
    end

    private

    def answer_for(question, name, state)
      custom = @responder&.call(question, name, state)
      custom || JevTestSupport.answer(question.type.to_sym, name)
    end
  end
end

class JevRailsTest < Minitest::Test
  def setup
    @client = JevTestSupport::RecordingClient.new
    Jev.client = @client
    ActiveRecord::Base.connection.execute("DELETE FROM jev_tickets")
  end

  def teardown
    Jev.instance_variable_set(:@client, nil)
  end

  attr_reader :client

  def model(&)
    JevTestSupport.model(&)
  end
end
