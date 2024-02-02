# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/newrelic-ruby-agent/blob/main/LICENSE for complete details.
# frozen_string_literal: true

module NewRelic::Agent::Instrumentation
  module OpenAI
    VENDOR = 'openAI'
    # TODO: should everything below be called embeddings if we renamed to chat completions?
    EMBEDDINGS_PATH = '/embeddings'
    CHAT_COMPLETIONS_PATH = '/chat/completions'
    SEGMENT_NAME_FORMAT = 'Llm/%s/OpenAI/create'

    # This method is defined in the OpenAI::HTTP module that is included
    # only in the OpenAI::Client class
    def json_post_with_new_relic(path:, parameters:)
      if path == EMBEDDINGS_PATH
        NewRelic::Agent.record_instrumentation_invocation(VENDOR)
        embedding_instrumentation(parameters) { yield }
      elsif path == CHAT_COMPLETIONS_PATH
        NewRelic::Agent.record_instrumentation_invocation(VENDOR)
        chat_completions_instrumentation(parameters) { yield }
      else
        yield
      end
    end

    private

    def embedding_instrumentation(parameters)
      segment = NewRelic::Agent::Tracer.start_segment(SEGMENT_NAME_FORMAT % 'embedding')
      record_openai_metric
      event = create_embedding_event(parameters)
      segment.embedding = event
      begin
        response = NewRelic::Agent::Tracer.capture_segment_error(segment) { yield }

        response
      ensure
        add_embedding_response_params(response, event) if response
        segment&.finish
        event&.error = true if segment_noticed_error?(segment) # need to test throwing an error
        event&.duration = segment&.duration
        event&.record # always record the event
      end
    end

    def chat_completions_instrumentation(parameters)
      # TODO: Do we have to start the segment outside the ensure block?
      segment = NewRelic::Agent::Tracer.start_segment(name: SEGMENT_NAME_FORMAT % 'completion')
      record_openai_metric
      event = create_chat_completion_summary(parameters)
      segment.chat_completion_summary = event
      messages = create_chat_completion_messages(parameters, summary_event_id)
      response = NewRelic::Agent::Tracer.capture_segment_error(segment) { yield }
      add_response_params(parameters, response, event) if response
      messages = update_chat_completion_messages(messages, response, event) if response

      response # return the response to the original caller
    ensure
      segment&.finish
      event&.error = true if segment_noticed_error?(segment)
      event&.duration = segment&.duration
      event&.record # always record the event
      messages&.each { |m| m&.record }
    end

    def create_chat_completion_summary(parameters)
      event = NewRelic::Agent::Llm::ChatCompletionSummary.new(
        # metadata => TBD, create API
        vendor: VENDOR,
        conversation_id: conversation_id,
        api_key_last_four_digits: parse_api_key,
        # TODO: Determine how to access parameters with keys as strings
        request_max_tokens: parameters[:max_tokens],
        request_model: parameters[:model],
        temperature: parameters[:temperature]
      )
    end

    def create_embedding_event(parameters)
      # TODO: Determine how to access parameters with keys as strings
      event = NewRelic::Agent::Llm::Embedding.new(
        # metadata => TBD, create API
        vendor: VENDOR,
        input: parameters[:input],
        api_key_last_four_digits: parse_api_key,
        request_model: parameters[:model]
      )
    end

    def add_response_params(parameters, response, event)
      event.response_number_of_messages = parameters[:messages].size + response['choices'].size
      event.response_model = response['model']
      event.response_usage_total_tokens = response['usage']['total_tokens']
      event.response_usage_prompt_tokens = response['usage']['prompt_tokens']
      event.response_usage_completion_tokens = response['usage']['completion_tokens']
      event.response_choices_finish_reason = response['choices'][0]['finish_reason']
    end

    def add_embedding_response_params(response, event)
      event.response_model = response['model']
      event.response_usage_total_tokens = response['usage']['total_tokens']
      event.response_usage_prompt_tokens = response['usage']['prompt_tokens']
    end

    def parse_api_key
      'sk-' + headers['Authorization'][-4..-1]
    end

    # The customer must call add_custom_attributes with conversation_id before
    # the transaction starts. Otherwise, the conversation_id will be nil
    def conversation_id
      return @nr_conversation_id if @nr_conversation_id

      @nr_conversation_id ||= NewRelic::Agent::Tracer.current_transaction.attributes.custom_attributes['conversation_id']
    end

    def create_chat_completion_messages(parameters, summary_id)
      # TODO: Determine how to access parameters with keys as strings
      parameters[:messages].map.with_index do |message, i|
        NewRelic::Agent::Llm::ChatCompletionMessage.new(
          content: message[:content] || message['content'],
          role: message[:role] || message['role'],
          sequence: i,
          completion_id: summary_id,
          vendor: VENDOR,
          is_response: false
        )
      end
    end

    def create_chat_completion_response_messages(response, sequence_origin, summary_id)
      response['choices'].map.with_index(sequence_origin) do |choice, i|
        NewRelic::Agent::Llm::ChatCompletionMessage.new(
          content: choice['message']['content'],
          role: choice['message']['role'],
          sequence: i,
          completion_id: summary_id,
          vendor: VENDOR,
          is_response: true
        )
      end
    end

    def update_chat_completion_messages(messages, response, summary)
      messages += create_chat_completion_response_messages(response, messages.size, summary.id)
      response_id = response['id'] || NewRelic::Agent::GuidGenerator.generate_guid

      messages.each do |message|
        # metadata => TBD, create API
        message.id = "#{response_id}-#{message.sequence}"
        message.conversation_id = conversation_id
        message.request_id = summary.request_id
        message.response_model = response['model']
      end
    end

    # Name is defined in Ruby 3.0+
    # copied from rails code
    # Parameter keys might be symbols and might be strings
    # response body keys have always been strings
    def hash_with_indifferent_access_whatever
      if Symbol.method_defined?(:name)
        key.kind_of?(Symbol) ? key.name : key
      else
        key.kind_of?(Symbol) ? key.to_s : key
      end
    end

    # the preceding :: are necessary to access the OpenAI module defined in the gem rather than the current module
    # TODO: discover whether this metric name should be prepended with 'Supportability'
    def record_openai_metric
      NewRelic::Agent.record_metric("Ruby/ML/OpenAI/#{::OpenAI::VERSION}", 0.0)
    end

    def segment_noticed_error?(segment)
      segment&.instance_variable_get(:@noticed_error)
    end
  end
end
