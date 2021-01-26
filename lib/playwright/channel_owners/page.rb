require 'base64'

module Playwright
  # @ref https://github.com/microsoft/playwright-python/blob/master/playwright/_impl/_page.py
  define_channel_owner :Page do
    include Utils::Errors::SafeCloseError
    attr_writer :owned_context

    def after_initialize
      @browser_context = @parent
      @timeout_settings = TimeoutSettings.new(@browser_context.send(:_timeout_settings))
      @accessibility = Accessibility.new(@channel)
      @keyboard = InputTypes::Keyboard.new(@channel)
      @mouse = InputTypes::Mouse.new(@channel)
      @touchscreen = InputTypes::Touchscreen.new(@channel)

      @viewport_size = @initializer['viewportSize']
      @closed = false
      @main_frame = ChannelOwners::Frame.from(@initializer['mainFrame'])
      @main_frame.send(:update_page_from_page, self)
      @frames = Set.new
      @frames << @main_frame

      @channel.once('close', ->(_) { on_close })
      @channel.on('console', ->(params) {
        console_message = ChannelOwners::ConsoleMessage.from(params['message'])
        emit(Events::Page::Console, console_message)
      })
      @channel.on('domcontentloaded', ->(_) { emit(Events::Page::DOMContentLoaded) })
      @channel.on('frameAttached', ->(params) {
        on_frame_attached(ChannelOwners::Frame.from(params['frame']))
      })
      @channel.on('frameDetached', ->(params) {
        on_frame_detached(ChannelOwners::Frame.from(params['frame']))
      })
      @channel.on('load', ->(_) { emit(Events::Page::Load) })
      @channel.on('popup', ->(params) {
        emit(Events::Page::Popup, ChannelOwners::Page.from(params['page']))
      })
    end

    attr_reader \
      :accessibility,
      :keyboard,
      :mouse,
      :touchscreen,
      :viewport_size,
      :main_frame

    private def on_frame_attached(frame)
      frame.send(:update_page_from_page, self)
      @frames << frame
      emit(Events::Page::FrameAttached, frame)
    end

    private def on_frame_detached(frame)
      @frames.delete(frame)
      frame.detached = true
      emit(Events::Page::FrameDetached, frame)
    end

    private def on_close
      @closed = true
      @browser_context.send(:remove_page, self)
      emit(Events::Page::Close)
    end

    def context
      @browser_context
    end

    def opener
      resp = @channel.send_message_to_server('opener')
      ChannelOwners::Page.from(resp)
    end

    def frame(frameSelector)
      name, url =
        if frameSelector.is_a?(Hash)
          [frameSelector[:name], frameSelector[:url]]
        else
          [frameSelector, nil]
        end

      if name
        @frames.find { |f| f.name == name }
      elsif url
        # ref: https://github.com/microsoft/playwright-python/blob/c4320c27cb080b385a5e45be46baa3cb7a9409ff/playwright/_impl/_helper.py#L104
        case url
        when String
          @frames.find { |f| f.url == url }
        when Regexp
          @frames.find { |f| url.match?(f.url) }
        else
          raise NotImplementedError.new('Page#frame with url is not completely implemented yet')
        end
      else
        raise ArgumentError.new('Either name or url matcher should be specified')
      end
    end

    def frames
      @frames.to_a
    end

    def query_selector(selector)
      @main_frame.query_selector(selector)
    end

    def query_selector_all(selector)
      @main_frame.query_selector_all(selector)
    end

    def evaluate(pageFunction, arg: nil)
      @main_frame.evaluate(pageFunction, arg: arg)
    end

    def evaluate_handle(pageFunction, arg: nil)
      @main_frame.evaluate_handle(pageFunction, arg: arg)
    end

    def eval_on_selector(selector, pageFunction, arg: nil)
      @main_frame.eval_on_selector(selector, pageFunction, arg: arg)
    end

    def eval_on_selector_all(selector, pageFunction, arg: nil)
      @main_frame.eval_on_selector_all(selector, pageFunction, arg: arg)
    end

    def url
      @main_frame.url
    end

    def content
      @main_frame.content
    end

    def set_content(html, timeout: nil, waitUntil: nil)
      @main_frame.set_content(html, timeout: timeout, waitUntil: waitUntil)
    end

    def goto(url, timeout: nil, waitUntil: nil, referer: nil)
      @main_frame.goto(url, timeout: timeout,  waitUntil: waitUntil, referer: referer)
    end

    def set_viewport_size(viewportSize)
      @viewport_size = viewportSize
      @channel.send_message_to_server('setViewportSize', { viewportSize: viewportSize })
      nil
    end

    def screenshot(
      path: nil,
      type: nil,
      quality: nil,
      fullPage: nil,
      clip: nil,
      omitBackground: nil,
      timeout: nil)

      params = {
        type: type,
        quality: quality,
        fullPage: fullPage,
        clip: clip,
        omitBackground: omitBackground,
        timeout: timeout,
      }.compact
      encoded_binary = @channel.send_message_to_server('screenshot', params)
      decoded_binary = Base64.decode64(encoded_binary)
      if path
        File.open(path, 'wb') do |f|
          f.write(decoded_binary)
        end
      end
      decoded_binary
    end

    def title
      @main_frame.title
    end

    def close(runBeforeUnload: nil)
      options = { runBeforeUnload: runBeforeUnload }.compact
      @channel.send_message_to_server('close', options)
      @owned_context&.close
      nil
    rescue => err
      raise unless safe_close_error?(err)
    end

    def closed?
      @closed
    end

    def click(
          selector,
          button: nil,
          clickCount: nil,
          delay: nil,
          force: nil,
          modifiers: nil,
          noWaitAfter: nil,
          position: nil,
          timeout: nil)

      @main_frame.click(
        selector,
        button: button,
        clickCount: clickCount,
        delay: delay,
        force: force,
        modifiers: modifiers,
        noWaitAfter: noWaitAfter,
        position: position,
        timeout: timeout,
      )
    end

    def focus(selector, timeout: nil)
      @main_frame.focus(selector, timeout: timeout)
    end

    def type_text(
      selector,
      text,
      delay: nil,
      noWaitAfter: nil,
      timeout: nil)

      @main_frame.type_text(selector, text, delay: delay, noWaitAfter: noWaitAfter, timeout: timeout)
    end

    def press(
      selector,
      key,
      delay: nil,
      noWaitAfter: nil,
      timeout: nil)

      @main_frame.press(selector, key, delay: delay, noWaitAfter: noWaitAfter, timeout: timeout)
    end

    class CrashedError < StandardError
      def initialize
        super('Page crashed')
      end
    end

    class AlreadyClosedError < StandardError
      def initialize
        super('Page closed')
      end
    end

    class FrameAlreadyDetachedError < StandardError
      def initialize
        super('Navigating frame was detached!')
      end
    end

    def wait_for_event(event, optionsOrPredicate: nil, &block)
      predicate, timeout =
        case optionsOrPredicate
        when Proc
          [optionsOrPredicate, nil]
        when Hash
          [optionsOrPredicate[:predicate], optionsOrPredicate[:timeout]]
        else
          [nil, nil]
        end
      timeout ||= @timeout_settings.timeout

      wait_helper = WaitHelper.new
      wait_helper.reject_on_timeout(timeout, "Timeout while waiting for event \"#{event}\"")

      unless event == Events::Page::Crash
        wait_helper.reject_on_event(self, Events::Page::Crash, CrashedError.new)
      end

      unless event == Events::Page::Close
        wait_helper.reject_on_event(self, Events::Page::Close, AlreadyClosedError.new)
      end

      wait_helper.wait_for_event(self, event, predicate: predicate)

      block&.call

      wait_helper.promise.value!
    end

    def wait_for_navigation(timeout: nil, url: nil, waitUntil: nil, &block)
      @main_frame.wait_for_navigation(
        timeout: timeout,
        url: url,
        waitUntil: waitUntil,
        &block)
    end

    def wait_for_request(urlOrPredicate, timeout: nil)
      predicate =
        case urlOrPredicate
        when String, Regexp
          url_matcher = UrlMatcher.new(urlOrPredicate)
          -> (req){ url_matcher.match?(req.url) }
        when Proc
          urlOrPredicate
        else
          -> (_) { true }
        end

      wait_for_event(Events::Page::Request, optionsOrPredicate: { predicate: predicate, timeout: timeout})
    end

    def wait_for_response(urlOrPredicate, timeout: nil)
      predicate =
        case urlOrPredicate
        when String, Regexp
          url_matcher = UrlMatcher.new(urlOrPredicate)
          -> (req){ url_matcher.match?(req.url) }
        when Proc
          urlOrPredicate
        else
          -> (_) { true }
        end

      wait_for_event(Events::Page::Response, optionsOrPredicate: { predicate: predicate, timeout: timeout})
    end

    # called from BrowserContext#on_page with send(:update_browser_context, page), so keep private.
    private def update_browser_context(context)
      @browser_context = context
      @timeout_settings = TimeoutSettings.new(context.send(:_timeout_settings))
    end

    # called from Frame with send(:timeout_settings)
    private def timeout_settings
      @timeout_settings
    end
  end
end