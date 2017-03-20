class MemberProfile < ApplicationRecord

  include JsonBuilder
  include AppConstants
  include PgSearch

  has_many :member_followings
  has_one  :user, as: :profile
  has_many :synchronizations
  has_many :member_groups
  has_many :posts
  has_many :user_albums
  has_many :events
  has_many :attended_events

  accepts_nested_attributes_for :user

  # after_create :create_default_group
  # validates :is_profile_public, inclusion: { in: [true, false] }

  @@limit = 10
  @@current_profile = nil


  pg_search_scope :search_by_name,
                  against: :name,
                  using: {
                      tsearch: {
                          any_word: true,
                          dictionary: "english"
                      }
                  }


  def self.sign_up(data)
    data = data.with_indifferent_access

    member_profile = MemberProfile.new
    member_profile.attributes = data[:member_profile]
    status, message = validate_email_and_password(data)
    if !status.present?
      if member_profile.save
        resp_status  = 1
        resp_message = 'Please check your email and verify your account.'
        resp_errors  = ''
      else
        resp_status  = 0
        resp_message = 'Errors'
        resp_errors  = error_messages(member_profile)
      end
    else
      resp_status  = 0
      resp_message = 'error'
      resp_errors  = message
    end
    resp_data = ''
    resp_request_id = data[:request_id] if data && data[:request_id].present?
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end

  def self.error_messages(error_array)
    error_string = ''
    error_array.errors.full_messages.each do |message|
      error_string += message + ', '
    end
    error_string
  end

  def self.validate_email_and_password(data)
    status  = false
    message = ''
    if data[:member_profile][:user_attributes][:password] != data[:member_profile][:user_attributes][:password_confirmation]
      message = "Password mismatch."
      status = true
    end
    [status, message]
  end

  def member_profile(auth_token=nil)
    member_profile = self.as_json(
        only: [:id, :about, :phone, :photo, :country_id, :state_id, :city_id, :is_profile_public, :default_group_id, :gender, :promotion_updates, :dob, :account_type, :height, :weight, :school],
        methods: [:posts_count,:followings_count, :followers_count],
        include: {
            user: {
                only: [:id, :profile_id, :profile_type, :first_name, :email, :last_name, :banner_image_1, :banner_image_2, :banner_image_3],
            }
        }
    ).merge!(auth_token: auth_token).as_json

    {member_profile: member_profile}.as_json
  end

  def self.social_media_sign_up(data)
    data = data.with_indifferent_access

    member_profile = MemberProfile.new
    member_profile.attributes = data[:member_profile]

    auth = UserAuthentication.find_from_social_data(member_profile.user.user_authentications.first)

    if auth.blank?
      if member_profile.user.email.present?
        user = User.find_by_email(member_profile.user.email)
      elsif member_profile.user.username.present?
        user = User.find_by_username(member_profile.user.username)
      end

      if user.present?
        UserAuthentication.create_from_social_data(member_profile.user.user_authentications.first, user)
        user.current_sign_in_at = Time.now
        user.synced_datetime = nil
        user.last_subscription_time = nil
        user.save!
        social_sign_up_response(data, user.profile)
      else

        password = SecureRandom.hex(10)
        member_profile.user.password = password
        member_profile.user.password_confirmation = password
        member_profile.is_profile_public = true #should be in migration default false : Later
        if member_profile.save
          user = member_profile.user
          user.current_sign_in_at = Time.now
          user.synced_datetime = nil
          user.last_subscription_time = nil
          user.save!
          social_sign_up_response(data, member_profile)
        else
          resp_data = ''
          resp_request_id = data[:request_id] if data && data[:request_id].present?
          resp_status = 0
          resp_message = 'errors'

          resp_errors = error_messages(member_profile)
          JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
        end
      end
    else
      # SignIn Here
      user = auth.user
      user.current_sign_in_at = Time.now
      user.synced_datetime = nil
      user.last_subscription_time = nil
      user.save!
      social_sign_up_response(data, auth.user.profile)
    end
  end

  def self.social_sign_up_response(data, profile)
    user = profile.user
    user_sessions = UserSession.where("device_uuid = ? AND user_id != ?", data[:user_session][:device_uuid], user.id)
    user_sessions.destroy_all if user_sessions.present?

    user_session = user.user_sessions.where(device_uuid: data[:user_session][:device_uuid]).try(:first) || user.user_sessions.build(data[:user_session])
    user_session.auth_token = SecureRandom.hex(100)
    user_session.session_status = 'open'
    user_session.save!

    resp_data = profile.member_profile(user_session.auth_token)
    resp_request_id = data[:request_id]
    resp_status = 1
    resp_message = 'success'
    resp_errors = ''
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end

  def self.get_profile(data, current_user)
    begin
      data          = data.with_indifferent_access
      profile       = MemberProfile.find_by_id(data[:member_profile_id])
      resp_data     = get_profile_response(profile, current_user)
      resp_status   = 1
      resp_message  = 'success'
      resp_errors   = ''
    rescue Exception => e
      resp_data     = ''
      resp_status   = 0
      paging_data   = ''
      resp_message  = 'error'
      resp_errors   = e
    end
    resp_request_id = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end

  def self.get_profile_response(profile, current_user)
    if profile.id == current_user.profile_id
      member_profile = profile.as_json(
          only: [:id, :about, :phone, :photo, :country_id, :state_id, :city_id, :is_profile_public, :default_group_id, :gender, :promotion_updates, :dob, :account_type, :height, :weight, :school],
          methods: [:posts_count, :followings_count, :followers_count],
          include: {
              user: {
                  only: [:id, :profile_id, :profile_type, :first_name, :email, :last_name, :banner_image_1, :banner_image_2, :banner_image_3]
              }
          }
      )
      {member_profile: member_profile}.as_json
    else
      member_profile = profile.to_xml(
          only: [:id, :about, :phone, :photo, :country_id, :state_id, :city_id, :is_profile_public, :default_group_id, :gender, :promotion_updates, :dob, :account_type, :height, :weight, :school],
          methods: [:posts_count, :followings_count, :followers_count],
          :procs => Proc.new { |options|
            options[:builder].tag!('is_im_following', MemberProfile.is_following(profile, current_user))
          },
          include: {
              user: {
                  only: [:id, :profile_id, :profile_type, :first_name, :email, :last_name, :banner_image_1, :banner_image_2, :banner_image_3]
              }
          }
      )
      Hash.from_xml(member_profile).as_json
    end
  end

  def self.account_update(data, current_user)
    begin
      data = data.with_indifferent_access
      profile = current_user.profile
      profile.account_type = data[:member_profile][:account_type]
      if profile.save
        resp_data = current_user.profile.member_profile
        resp_status = 1
        resp_message = 'success'
        resp_errors = ''
      else
        resp_data = ''
        resp_status = 0
        resp_message = 'error'
        resp_errors = error_messages(profile)
      end
    rescue Exception => e
      resp_data = ''
      resp_status = 0
      paging_data = ''
      resp_message = 'error'
      resp_errors = e
    end

    resp_request_id = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end

  def self.update(data, current_user)
    begin
      data = data.with_indifferent_access
      profile = current_user.profile
      if data[:user].present?
        current_user.update_attributes(data[:user])
        current_user = User.find_by_id(current_user.id)
      end
      if profile.update_attributes(data[:member_profile])
        resp_data = current_user.profile.member_profile
        resp_status = 1
        resp_message = 'success'
        resp_errors = ''
      else
        resp_data = ''
        resp_status = 0
        resp_message = 'error'
        resp_errors = error_messages(profile)
      end
    rescue Exception => e
      resp_data = ''
      resp_status = 0
      paging_data = ''
      resp_message = 'error'
      resp_errors = e
    end
    resp_request_id = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end

  def self.image_upload(data, current_user)
    begin
      data = data.with_indifferent_access
      profile = current_user.profile
      profile.update_attributes(data[:member_profile])
      resp_data = profile.member_profile
      resp_status = 1
      resp_message = 'success'
      resp_errors = ''
    rescue Exception => e
      resp_data = ''
      resp_status = 0
      paging_data = ''
      resp_message = 'error'
      resp_errors = e
    end
    resp_request_id = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end

  def is_im_following
    member_followings = MemberFollowing.where(member_profile_id: @@current_profile.id, following_profile_id: self.id, is_deleted: false)
    if member_followings.blank?
      0
    elsif member_followings.present? && member_followings.first.following_status == AppConstants::ACCEPTED
      1
    elsif member_followings.present? && member_followings.first.following_status == AppConstants::PENDING
      2
    elsif member_followings.present? && member_followings.first.following_status == AppConstants::REJECTED
      3
    end
  end

  def self.is_following(profile, current_user)
    member_followings = MemberFollowing.where(member_profile_id: current_user.profile_id, following_profile_id: profile.id, is_deleted: false)
    if member_followings.blank?
      0
    elsif member_followings.present? && member_followings.first.following_status == AppConstants::ACCEPTED
      1
    elsif member_followings.present? && member_followings.first.following_status == AppConstants::PENDING
      2
    elsif member_followings.present? && member_followings.first.following_status == AppConstants::REJECTED
      3
    end
  end

  def posts_count
    self.posts.count
  end

  def followings_count
    self.member_followings.where(following_status: AppConstants::ACCEPTED).count
  end

  def followers_count
    MemberFollowing.where(following_profile_id: self.id, following_status: AppConstants::ACCEPTED).count
  end

  def is_my_follower
    member_followers = MemberFollowing.where(following_status: AppConstants::ACCEPTED, member_profile_id: self.id, following_profile_id: @@current_profile.id)
    if member_followers.present?
      true
    else
      false
    end
  end

  def self.profile_timeline(data, current_user)
     begin
      data         = data.with_indifferent_access
      per_page     = (data[:per_page] || @@limit).to_i
      page         = (data[:page] || 1).to_i

      profile = current_user.profile
      posts        = profile.posts
      if posts.present?
        posts         = posts.order("created_at DESC")
        posts         = posts.page(page.to_i).per_page(per_page.to_i)

        paging_data   = JsonBuilder.get_paging_data(page, per_page, posts)
        resp_data     = Post.timeline_posts_array_response(posts, profile, current_user)
        resp_status   = 1
        resp_message  = 'TimeLine'
        resp_errors   = ''
      else
        resp_data = ''
        resp_status = 0
        resp_message = 'No Post Found.'
        resp_errors = ''
        paging_data = ''
    end
    rescue Exception => e
      resp_data    = ''
      resp_status  = 0
      paging_data  = ''
      resp_message = 'error'
      resp_errors  = e
    end
    resp_request_id = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, paging_data: paging_data)
  end

  def self.other_member_profile(data, current_user)
    begin
      data = data.with_indifferent_access
      profile = MemberProfile.find_by_id(data[:member_profile][:id])

      if profile && profile.is_profile_public.present?
        resp_data = other_member_profile_public_response(profile, current_user)
        resp_message = 'Public Profile'
      else
        resp_data = profile.other_member_profile_private_response
        resp_message = 'Private Profile'
      end
      resp_status = 1
      resp_errors = ''
    rescue Exception => e
      resp_data = ''
      resp_status = 0
      paging_data = ''
      resp_message = 'error'
      resp_errors = e
    end

    resp_request_id = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end

  def other_member_profile_private_response
    member_profile = self.as_json(
        only: [:id, :about, :photo, :country_id, :gender, :height, :weight, :school],
        methods: [:posts_count, :followers_count, :followings_count],
        include: {
            user: {
                only: [:id, :first_name, :last_name, :email]
            }
        }

    )
    {member_profile: member_profile}.as_json
  end

  def self.other_member_profile_public_response(profile, current_user)
    @@current_profile = current_user.profile
    member_profile = profile.as_json(
        only: [:id, :about, :phone, :photo, :cover, :country_id, :is_profile_public, :gender, :dob, :height, :weight, :school],
        methods: [:posts_count, :followers_count, :followings_count, :is_im_following, :is_my_follower],
        include: {
            user: {
                only: [:id, :first_name, :last_name, :email]
            }
        }
    )
    member_followings = profile.member_followings.where(following_status: ACCEPTED, is_deleted: false)
    member_followings = member_followings.order("updated_at DESC")
    member_followings = member_followings.limit(@@limit)
    member_followings = MemberFollowing.member_followings_response(member_followings, current_user, profile, MEMBER_FOLLOWINGS, false)

    posts = profile.posts.where(is_post_public: true, is_deleted: false)
    posts = posts.order("updated_at DESC")
    posts = posts.limit(@@limit)
    posts = Post.other_member_profile_posts_response(posts, profile)

    member_followers = MemberFollowing.where(following_profile_id: profile.id, following_status: ACCEPTED, is_deleted: false)
    member_followers = member_followers.order("updated_at DESC")
    member_followers = member_followers.limit(@@limit)
    member_followers = MemberFollowing.member_followings_response(member_followers, current_user, profile, MEMBER_FOLLOWERS, false)


    {member_profile: member_profile, posts: posts, member_followings: member_followings, member_followers: member_followers}.as_json
  end






end


# == Schema Information
#
# Table name: member_profiles
#
#  id                :integer          not null, primary key
#  photo             :string           default("http://bit.ly/25CCXzq")
#  country_id        :integer
#  school_name       :string
#  is_profile_public :boolean
#  default_group_id  :integer
#  gender            :string
#  dob               :string
#  promotion_updates :boolean          default(FALSE)
#  state_id          :integer
#  city_id           :integer
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  sport_id          :integer
#  sport_position_id :integer
#  sport_level_id    :integer
#  account_type      :string
#
