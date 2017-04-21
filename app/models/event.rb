class Event < ApplicationRecord
  include JsonBuilder
  include PgSearch
  
  @@limit           = 10
  @@current_profile = nil
  
  has_many :posts
  has_many :event_tags, dependent: :destroy
  has_many :hashtags, through: :event_tags
  belongs_to :post   #this only for wiining post
  
  after_commit :process_hashtags
  pg_search_scope :search_by_title,
    against: :description,
    using: {
        tsearch: {
            any_word: true,
            dictionary: "english"
        }
    }
  
  def post_count
    self.posts.count
  end

  def process_hashtags
    arr = []
    hashtag_regex, current_user = /\B#\w\w+/
    text_hashtags_title = hash_tag.scan(hashtag_regex) if hash_tag.present?
    arr << text_hashtags_title
    tags = (arr.flatten).uniq
    ids = []
    tags.each do |ar|
      tag = Hashtag.find_by_name(ar)
      if tag.present?
        tag.count = tag.count+1
        tag.save!
      else
        tag = Hashtag.create!(name: ar)
      end
      event_tag = EventTag.find_by_event_id_and_hashtag_id(self.id, tag.id)
      if event_tag.blank?
        EventTag.create!(event_id: self.id, hashtag_id: tag.id)
      end
      ids << tag.id
    end
    EventTag.where("event_id = ? AND hashtag_id NOT IN(?)", self.id, ids).try(:destroy_all)
  end
  
  def self.event_create(data, current_user)
    begin
      data    = data.with_indifferent_access
      profile = current_user.profile
      event   = profile.events.build(data[:event])
      if event.save
        resp_data       = ''
        resp_status     = 1
        resp_message    = 'Event Created'
        resp_errors     = ''
      else
        resp_data       = ''
        resp_status     = 0
        resp_message    = 'Errors'
        resp_errors     = event.errors.messages
      end
    rescue Exception => e
      resp_data       = ''
      resp_status     = 0
      paging_data     = ''
      resp_message    = 'error'
      resp_errors     = e
    end
    resp_request_id = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end

  def self.show_event(data, current_user)
    begin
      data  = data.with_indifferent_access
      event = Event.find_by_id(data[:id])
      resp_data       = event_response(event)
      resp_status     = 1
      resp_message    = 'Event details'
      resp_errors     = ''
    rescue Exception => e
      resp_data       = ''
      resp_status     = 0
      paging_data     = ''
      resp_message    = 'error'
      resp_errors     = e
    end
    resp_request_id   = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end
  
  def self.event_list(data, current_user)
    begin
      data = data.with_indifferent_access
      max_event_date = data[:max_event_date] || DateTime.now
      min_event_date = data[:min_event_date] || DateTime.now
      
      events      = Event.all
      if data[:start_date].present? && data[:end_date].present?
        events    = Event.where('start_date >= ? AND end_date <= ? AND is_deleted = false', data[:start_date], data[:end_date])
      end
      
      if data[:search_key].present?
        events  = events.where("lower(name) like ? ", "%#{data[:search_key]}%".downcase)
      end

      if data[:max_event_date].present?
        events = events.where("created_at > ?", max_event_date)
      elsif data[:min_event_date].present?
        events = events.where("created_at < ?", min_event_date)
      end
      events = events.order("created_at DESC")
      events = events.limit(@@limit)

      if events.present?
        Event.where("created_at > ?", events.first.created_at).present? ? previous_page_exist = true : previous_page_exist = false
        Event.where("created_at < ?", events.last.created_at).present? ? next_page_exist = true : next_page_exist = false
      end
      
      paging_data = {next_page_exist: next_page_exist, previous_page_exist: previous_page_exist}
      resp_data       = events_response(events)
      resp_status     = 1
      resp_message    = 'Event List'
      resp_errors     = ''
    rescue Exception => e
      resp_data       = {}
      resp_status     = 0
      paging_data     = ''
      resp_message    = 'error'
      resp_errors     = e
    end
    resp_request_id   = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, paging_data: paging_data)
  end
  
  def self.global_winners(data, current_user)
    begin
      data = data.with_indifferent_access
      max_event_date = data[:max_event_date] || DateTime.now
      min_event_date = data[:min_event_date] || DateTime.now
      
      if data[:max_event_date].present?
        events  = Event.where('end_date > ? AND end_date < ? AND is_deleted = false', max_event_date, DateTime.now)
      elsif data[:min_event_date].present?
        events  = Event.where('end_date < ? AND is_deleted = false', min_event_date)
      else
        events  = Event.where('end_date < ? AND is_deleted = false', DateTime.now)
      end
      events = events.where('post_id IS NOT NULL')
      
      # posts = []
      # last_event_date  = ''
      # events && events.each do |event|
      #   posts << Post.joins(:likes).select("posts.*, COUNT('likes.id') likes_count").where(likes: {likable_type: 'Post', is_like: true}, event_id: event.id).group('posts.id').order('likes_count DESC').try(:first)
      #   if posts.count >= 10
      #     break
      #   end
      #   last_event_date = event.end_date
      # end

      events = events.order("end_date DESC")
      events = events.limit(@@limit)

      if events.present?
        Event.where("end_date > ? AND end_date < ?", events.first.end_date, DateTime.now).present? ? previous_page_exist = true : previous_page_exist = false
        Event.where("end_date < ?", events.last.end_date).present? ? next_page_exist = true : next_page_exist = false
      end

      paging_data = {next_page_exist: next_page_exist, previous_page_exist: previous_page_exist}
      resp_data   = winners_response(events)
     
      resp_status = 1
      resp_message = 'Event list'
      resp_errors = ''
    rescue Exception => e
      resp_data       = {}
      resp_status     = 0
      paging_data     = ''
      resp_message    = 'error'
      resp_errors     = e
    end
    resp_request_id   = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, paging_data: paging_data)
  end

  def self.leader_winners(data, current_user)
    begin
      data = data.with_indifferent_access
      max_event_date = data[:max_event_date] || DateTime.now
      min_event_date = data[:min_event_date] || DateTime.now
    
      if data[:max_event_date].present?
        events  = Event.where('end_date > ? AND end_date < ?', max_event_date, DateTime.now)
      elsif data[:min_event_date].present?
        events  = Event.where('end_date < ?', min_event_date)
      else
        events  = Event.where('end_date < ?', DateTime.now)
      end
      events = events.where('post_id IS NOT NULL')
      
      following_ids = current_user.profile.member_followings.where(following_status: AppConstants::ACCEPTED, is_deleted: false).pluck(:following_profile_id)
      events = events.where(winner_profile_id: following_ids)

      events = events.order("end_date DESC")
      events = events.limit(@@limit)

      if events.present?
        Event.where("end_date > ? AND end_date < ?", events.first.end_date, DateTime.now).present? ? previous_page_exist = true : previous_page_exist = false
        Event.where("end_date < ? AND winner_profile_id IN (?)", events.last.end_date, following_ids).present? ? next_page_exist = true : next_page_exist = false
      end
      
      paging_data = {next_page_exist: next_page_exist, previous_page_exist: previous_page_exist}
      resp_data   = winners_response(events)
      resp_status = 1
      resp_message = 'Event list'
      resp_errors = ''
    rescue Exception => e
      resp_data       = {}
      resp_status     = 0
      paging_data     = ''
      resp_message    = 'error'
      resp_errors     = e
    end
    resp_request_id   = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, paging_data: paging_data)
  end

  def self.events_response(events)
    events = events.as_json(
        only:    [:id, :name, :location, :description, :start_date, :end_date, :created_at, :updated_at],
        methods: [:post_count],
        include:{
            hashtags:{
                only:[:id, :name]
            }
        }
    )
    { events: events }.as_json
  end

  def self.event_response(event)
    event = event.as_json(
        only:[:id, :name, :location, :start_date, :end_date, :is_deleted, :hash_tag],
        include:{
            hashtags:{
                only:[:id, :name]
            }
        }
    )

    events_array = []
    events_array << event

    { events: events_array }.as_json
  end

  def self.winners_response(events)
    events = events.as_json(
        only:    [:id, :name, :location, :start_date, :end_date],
        include:{
            hashtags:{
                only:[:id, :name]
            },
            post:{
                only:[:id, :post_title],
                methods: [:likes_count],
                include:{
                    post_attachments: {
                        only: [:attachment_url, :thumbnail_url, :attachment_type, :width, :height]
                    },
                    member_profile: {
                        only: [:id, :photo],
                        include: {
                            user: {
                                only: [:id, :username, :email]
                            }
                        }
                    }
                }
            }
        }
        
    )
  
    { events: events }.as_json
  end
end