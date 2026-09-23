# frozen_string_literal: true

require "json"

module Canned
  REQUEST = {
    "state" => "Customer: my invoice is wrong again and nobody answers. This is the third time.",
    "model" => "jev-latest",
    "questions" => {
      "urgent" => {
        "type" => "noul",
        "instructions" => "Is this message urgent?",
        "criteria" => { "true" => "needs a reply today", "false" => "can wait" }
      },
      "topic" => {
        "type" => "choice",
        "instructions" => "Which team should handle this?",
        "criteria" => {
          "billing" => "invoices, refunds, payment methods",
          "technical" => "bugs, outages, integrations",
          "sales" => "pricing, upgrades, new contracts"
        }
      },
      "anger" => {
        "type" => "score",
        "instructions" => "How angry is the customer?",
        "criteria" => ["Calm", "Frustrated", "Very angry"]
      }
    }
  }.freeze

  RESPONSE = {
    "model" => "jev-1.13.0",
    "answers" => {
      "urgent" => { "type" => "noul", "noul" => 0.96 },
      "topic" => {
        "type" => "choice",
        "choice" => "billing",
        "confidence" => 0.88,
        "probabilities" => { "billing" => 0.92, "technical" => 0.08, "sales" => 0.0 }
      },
      "anger" => {
        "type" => "score",
        "score" => 1.22,
        "confidence" => 0.67,
        "legend" => { "0" => "Calm", "1" => "Frustrated", "2" => "Very angry" },
        "probabilities" => { "0" => 0.0, "1" => 0.78, "2" => 0.22 }
      }
    },
    "usage" => { "input_tokens" => 430, "output_tokens" => 73 }
  }.freeze

  NOUL_ANSWER = RESPONSE.dig("answers", "urgent")
  CHOICE_ANSWER = RESPONSE.dig("answers", "topic")
  SCORE_ANSWER = RESPONSE.dig("answers", "anger")

  RATE_LIMIT_ERROR = {
    "error" => { "type" => "rate_limit_error", "message" => "too many requests" }
  }.freeze

  SERVER_ERROR = {
    "error" => { "type" => "server_error", "message" => "internal error" }
  }.freeze

  AUTH_ERROR = {
    "error" => { "type" => "authentication_error", "message" => "missing or empty bearer token" }
  }.freeze

  module_function

  def request_json
    JSON.generate(REQUEST)
  end

  def response_json
    JSON.generate(RESPONSE)
  end

  def questions
    {
      urgent: Judge.noul("Is this message urgent?",
                         { "true" => "needs a reply today", "false" => "can wait" }, name: :urgent),
      topic: Judge.choice("Which team should handle this?",
                          REQUEST.dig("questions", "topic", "criteria"), name: :topic),
      anger: Judge.score("How angry is the customer?", ["Calm", "Frustrated", "Very angry"], name: :anger)
    }
  end

  def state
    REQUEST["state"]
  end
end
