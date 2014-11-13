#!/usr/bin/env ruby
require 'faraday'
require 'json'
require 'yaml'
require 'erb'
require 'date'

filename = __FILE__.gsub(/\.rb$/,'.yml')
Setting = YAML::load(ERB.new(IO.read(filename)).result)

class LunchBot

  def initialize(chat_work_setting)
    @order_hash   = {}
    @user_hash    = {}
    @warning_list = []
    @ChatWorkSetting = chat_work_setting['ChatWork']
    @order_template = []
    @option_template = @ChatWorkSetting['OptionTemplate']
    @today_name = Date::DAYNAMES[Date.today.wday]
    if @ChatWorkSetting['OrderTemplate'].key?(@today_name)
      @order_template += @ChatWorkSetting['OrderTemplate'][@today_name]
    end
    if @ChatWorkSetting['PairOrderTemplate'].key?(@today_name)
      @order_template += @ChatWorkSetting['PairOrderTemplate'][@today_name]
      @order_template += @ChatWorkSetting['PairOrderTemplate'][@today_name].combination(2).collect{|r| r.join(",") }
    end
    raise 'no reservation day' if @order_template.size.zero?
    @faraday = Faraday.new(url: @ChatWorkSetting['Url']) do |faraday|
      faraday.response :logger
      faraday.adapter  Faraday.default_adapter
    end
  end

  def run
    task_list = scrape_and_generate_task_list
    run_option_if_last_task_is_option(task_list)
    rearrange_task_list(task_list)
    report
  end

  private

  def scrape_and_generate_task_list
    response = @faraday.get do |r|
      r.url '/v1/rooms/%s/tasks?status=open&account_id=%s' % [ @ChatWorkSetting['Room'], @ChatWorkSetting['AssignedByAccount'] ]
      r.headers['X-ChatWorkToken'] = @ChatWorkSetting['Token']
    end
    raise 'no assigned task' if response.body.size.zero?
    JSON.parse(response.body)
  end

  def run_option_if_last_task_is_option(task_list)
    last_task = task_list.last
    return true unless @option_template.include?(last_task['body'])

    post_list if last_task['body'] == 'list'
  end

  def post_list
    report(@order_template.join("\n"))
    exit
  end

  def rearrange_task_list(task_list)
    task_list.each do |task|
      @user_hash.store( task['assigned_by_account']['account_id'], task['assigned_by_account']['name'] )
      unless @order_template.include?(task['body'])
        if @option_template.include?(task['body'])
          next
        end
        @warning_list << { account_id: task['assigned_by_account']['account_id'], order: task['body'] }
        next
      end
      if @order_hash.key?(task['body'])
        @order_hash[task['body']] << task['assigned_by_account']['account_id']
      else
        @order_hash[task['body']] = [task['assigned_by_account']['account_id']]
      end
    end
  end

  def create_message
    message = '[info]'
    @order_hash.each do |menu,queue|
      message << "[title]%s(%d)[/title] %s" % [ menu, queue.size, queue.map{|r| "[picon:#{r}]" }.join ]
    end
    message << '[/info]'
    unless @warning_list.size.zero?
      message << "\n[hr]Warning[hr]\n"
      message << @warning_list.map do |r|
        "[To:%s] %s さん 注文【%s】 を、私は解釈出来ません。力足らずごめんなさい。" % [ r[:account_id], @user_hash[r[:account_id]], r[:order] ]
      end.join("\n")
      message << "\n[info][title]オーダー可能なメニュー(こちらをコピーしてください)[/title]%s[/info]" % @order_template.join("\n")
    end

    message
  end

  def report(message = nil)
    message ||= create_message

    @faraday.post do |r|
      r.url '/v1/rooms/%s/messages' % @ChatWorkSetting['Room']
      r.headers['X-ChatWorkToken'] = @ChatWorkSetting['Token']
      r.params[:body] = '[info]%s[/info]' % message
    end
  end
end

begin
  lunch_bot = LunchBot.new(Setting)
  lunch_bot.run
rescue => ex
  puts ex.message
  puts ex.backtrace.inspect
end
