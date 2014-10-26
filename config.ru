require 'sinatra'
require 'sinatra/reloader'
require 'server'
require 'json'
require 'pp'
require 'open-uri'
require 'openssl'
require 'rss'
require "rexml/document"
require 'aws-sdk'

set :environment, :production
 
class Bread < Sinatra::Base
  get '/show' do
    articles = select_article(crawl_data)
    api_data = seasoning_article(articles)
    regist_queue(api_data)
   
    api_data.to_json
  end
  
  # データの収集、パース
  def crawl_data
    ret = Hash.new
#    ret['sumamachi'] = crawl_sumamachi
    ret['asahi'] = crawl_asahi
    ret['nikkei'] = crawl_nikkei
    ret['mainichi'] = crawl_mainichi
    ret['sankei'] = crawl_sankei
    ret['yomiuri'] = crawl_yomiuri
    return ret
  end
  
  # スマ町データの収集、パース
  def crawl_sumamachi
    res = open('')
    code, message = res.status
    if code != '200'
      return nil
    end
  
    raw_data = JSON.parse(res.read)
    articles = Array.new
    raw_data['recent']['entries'].each do |entry|
      article = Hash.new
      article['title'] = entry['title']
  #    article['description'] = entry['description']
      article['text'] = entry['text']
  #    article['image'] = entry['thumbnail']
      articles.push(article)
    end
    return articles
  end
  # 朝日新聞データの収集、パース
  def crawl_asahi
    res = open('')
    code, message = res.status
    if code != '200'
      return nil
    end
  
    raw_data = JSON.parse(res.read)
    articles = Array.new
    raw_data['response']['result']['doc'].each do |entry|
      article = Hash.new
      article['title'] = entry['Title']
      article['text'] = entry['Body']
      articles.push(article)
      # 重いので、一旦1記事を取ったらreturn
      articles.push(article)
      if articles.length > 0
        return articles
      end
    end
    return articles
  end
  
  # 日経新聞データの収集、パース
  def crawl_nikkei
    res = open('')
    code, message = res.status
    if code != '200'
      return nil
    end
  
    raw_data = JSON.parse(res.read)
    articles = Array.new
    raw_data['articles'].each do |entry|
      article = Hash.new
      article['title'] = entry['title']
      # kiji_idに対応する記事を取得する
      res = open('')
      code, message = res.status
      if code != '200'
        next
      end
      kiji_data = JSON.parse(res.read)
      article['text'] = kiji_data['body']
      article['text'].gsub!(/<\/?[^>]*>/, "")
      articles.push(article)
      # 重いので、一旦1記事を取ったらreturn
      articles.push(article)
      if articles.length > 0
        return articles
      end
    end
    return articles
  end
  
  # 毎日新聞データの収集、パース
  def crawl_mainichi
    rss = RSS::Parser.parse('', false)
    articles = Array.new
    # item = rss.items.first
    rss.items.each do |item|
      article = Hash.new
      article['title'] = item.title
      # RSSのリンクの記事を取得
      res = open(item.link)
      code, message = res.status
      if code != '200'
        next
      end
      raw = res.read
      # 記事本文の抽出
      body = raw.match(/<!-- 本文＆段落写真 -->\n([\s\S]*)\n<!-- 本文＆段落写真 -->/)
      if body.nil?
        next
      end
      # 不要タグ等の除去
      article['text'] = body[1].delete("\n")
      article['text'].gsub!(/<\/?[^>]*>/, "")
      # 重いので、一旦1記事を取ったらreturn
      articles.push(article)
      if articles.length > 0
        return articles
      end
    end
    return articles
  end
  
  # 産経新聞データの収集、パース
  def crawl_sankei
    res = open('')
    code, message = res.status
    if code != '200'
      return nil
    end
    doc = REXML::Document.new res
    articles = Array.new
    doc.elements.each('/response/result/doc') do |item|
      article = Hash.new
      article['title'] = item.elements['Title'].text
      article['text'] = item.elements['Body'].text
      articles.push(article)
      # 重いので、一旦1記事を取ったらreturn
      articles.push(article)
      if articles.length > 0
        return articles
      end
    end
    return articles
  end

  # 読売新聞データの収集、パース
  def crawl_yomiuri
    certs =  ['', '']
    res = open('', {:http_basic_authentication => certs})
    code, message = res.status
    if code != '200'
      return nil
    end
    doc = REXML::Document.new res
    articles = Array.new
    article = Hash.new
    article['title'] = doc.elements['/rdf:RDF/item/title'].text
    article['text'] = doc.elements['/rdf:RDF/item/content:encoded'].text
    articles.push(article)
    return articles
  end
  
  # 記事の選定
  def select_article(articles)
    ret = Hash.new
    articles.each do |company,entries|
      if entries.nil?
        next
      end
      ret[company] = entries.first
    end
    return ret
  end
  
  # 記事のポジネガ判定(味付け)
  def seasoning_article(articles)
    ret = Hash.new
    articles.each do |company,article|
      if article.nil?
        next
      end
      ret[company] = article
      if article['text'].nil?
        ret[company].store('taste', nil)
        next
      end
  
      # 文字数制限回避のため、一旦1000文字で区切る
      if article['text'].length > 1000
        split_text = article['text'].scan(/.{1,1000}/)
        sent_param = split_text[0]
      else
        sent_param = article['text']
      end
  
      url = '' + sent_param
      url_escape = URI.escape(url)
      certs =  ['', '']
      res = open(url_escape, {:http_basic_authentication => certs})
      code, message = res.status
      
      if code == '200'
        analyzed_data = JSON.parse(res.read)
        ret[company].store('taste', analyzed_data['results'][0]['spn'])
      end
    end
    return ret
  end

  def regist_queue(api_data)
    sqs = AWS::SQS.new(
      :access_key_id => "",
      :secret_access_key => ""
    )

    # 対象のqueueのurlを取得(WEBのコンソール画面から)
    queue_url = ""

    # queueに登録するメッセージ
    queue_msg = api_data.to_json

    # queueにメッセージを登録
    sqs.queues[queue_url].send_message(queue_msg)
  end
end

run Bread
