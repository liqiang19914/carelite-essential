export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

export type UserRole = 'user' | 'manager' | 'admin';
export type CertificationStatus = 'pending' | 'approved' | 'rejected';
export type SurveyStatus = 'draft' | 'active' | 'closed';

export interface Database {
  __InternalSupabase: {
    PostgrestVersion: "13.0.4";
  };
  public: {
    Tables: {
      profiles: {
        Row: {
          id: string;
          phone: string | null;
          nickname: string | null;
          avatar_url: string | null;
          role: UserRole;
          is_verified: boolean;
          real_name: string | null;
          id_card: string | null;
          is_disabled: boolean;
          disabled_at: string | null;
          disabled_reason: string | null;
          invited_by: string | null;
          wechat_openid: string | null;
          wechat_nickname: string | null;
          wechat_avatar: string | null;
          wechat_unionid: string | null;
          phone_bindable: boolean;
          parent_manager_id: string | null;
          sub_role: string;
          wecom_userid: string | null;
          wecom_bound_at: string | null;
          permissions: Json;
          voice_preference: string;
          privacy_settings: Json;
          notification_settings: Json;
          member_code: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id: string;
          phone?: string | null;
          nickname?: string | null;
          avatar_url?: string | null;
          role?: UserRole;
          is_verified?: boolean;
          real_name?: string | null;
          id_card?: string | null;
          is_disabled?: boolean;
          disabled_at?: string | null;
          disabled_reason?: string | null;
          invited_by?: string | null;
          wechat_openid?: string | null;
          wechat_nickname?: string | null;
          wechat_avatar?: string | null;
          wechat_unionid?: string | null;
          phone_bindable?: boolean;
          parent_manager_id?: string | null;
          sub_role?: string;
          permissions?: Json;
          voice_preference?: string;
          privacy_settings?: Json;
          notification_settings?: Json;
          member_code?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          phone?: string | null;
          nickname?: string | null;
          avatar_url?: string | null;
          role?: UserRole;
          is_verified?: boolean;
          real_name?: string | null;
          id_card?: string | null;
          is_disabled?: boolean;
          disabled_at?: string | null;
          disabled_reason?: string | null;
          invited_by?: string | null;
          wechat_openid?: string | null;
          wechat_nickname?: string | null;
          wechat_avatar?: string | null;
          wechat_unionid?: string | null;
          phone_bindable?: boolean;
          parent_manager_id?: string | null;
          sub_role?: string;
          permissions?: Json;
          voice_preference?: string;
          privacy_settings?: Json;
          notification_settings?: Json;
          member_code?: string | null;
          created_at?: string;
          updated_at?: string;
        };
      };
      managers: {
        Row: {
          id: string;
          business_name: string | null;
          business_license: string | null;
          certification_status: CertificationStatus;
          membership_level: string;
          membership_expires_at: string | null;
          client_count: number;
          survey_count: number;
          invite_code: string | null;
          intro_personal: string | null;
          intro_company: string | null;
          company_name: string | null;
          digital_avatar_image_url: string | null;
          digital_persona_video_url: string | null;
          digital_persona_source_platform: string | null;
          digital_persona_source_asset_id: string | null;
          digital_persona_playback_url: string | null;
          digital_persona_format: string | null;
          digital_persona_status: string | null;
          digital_persona_verified_at: string | null;
          digital_persona_last_error: string | null;
          tagline: string | null;
          credentials: string[] | null;
          partner_phone: string | null;
          partner_card_status: string | null;
          partner_card_public_url: string | null;
          partner_card_slug: string | null;
          partner_card_display_name: string | null;
          partner_card_avatar_url: string | null;
          partner_card_company_name: string | null;
          partner_card_updated_at: string | null;
          partner_card_synced_at: string | null;
          partner_card_error: string | null;
          featured_product_ids: string[];
          is_example: boolean;
          knowledge_index_id: string | null;
          knowledge_index_status: string | null;
          knowledge_model: string | null;
          knowledge_system_prompt: string | null;
          knowledge_category_id: string | null;
          public_qa_enabled: boolean;
          public_qa_welcome_message: string | null;
          public_qa_lead_capture_mode: string;
          short_code: string | null;
          submitted_at: string | null;
          reviewed_at: string | null;
          reviewed_by: string | null;
          review_note: string;
          membership_enforcement_mode: string;
          seat_limit_override: number | null;
          client_limit_override: number | null;
          membership_updated_at: string | null;
          membership_updated_by: string | null;
          membership_note: string | null;
          public_contact_phone: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id: string;
          business_name?: string | null;
          business_license?: string | null;
          certification_status?: CertificationStatus;
          membership_level?: string;
          membership_expires_at?: string | null;
          client_count?: number;
          survey_count?: number;
          invite_code?: string | null;
          intro_personal?: string | null;
          intro_company?: string | null;
          company_name?: string | null;
          digital_avatar_image_url?: string | null;
          digital_persona_video_url?: string | null;
          digital_persona_source_platform?: string | null;
          digital_persona_source_asset_id?: string | null;
          digital_persona_playback_url?: string | null;
          digital_persona_format?: string | null;
          digital_persona_status?: string | null;
          digital_persona_verified_at?: string | null;
          digital_persona_last_error?: string | null;
          tagline?: string | null;
          credentials?: string[] | null;
          partner_phone?: string | null;
          partner_card_status?: string | null;
          partner_card_public_url?: string | null;
          partner_card_slug?: string | null;
          partner_card_display_name?: string | null;
          partner_card_avatar_url?: string | null;
          partner_card_company_name?: string | null;
          partner_card_updated_at?: string | null;
          partner_card_synced_at?: string | null;
          partner_card_error?: string | null;
          featured_product_ids?: string[];
          is_example?: boolean;
          knowledge_index_id?: string | null;
          knowledge_index_status?: string | null;
          knowledge_model?: string | null;
          knowledge_system_prompt?: string | null;
          knowledge_category_id?: string | null;
          public_qa_enabled?: boolean;
          public_qa_welcome_message?: string | null;
          public_qa_lead_capture_mode?: string;
          short_code?: string | null;
          submitted_at?: string | null;
          reviewed_at?: string | null;
          reviewed_by?: string | null;
          review_note?: string;
          membership_enforcement_mode?: string;
          seat_limit_override?: number | null;
          client_limit_override?: number | null;
          membership_updated_at?: string | null;
          membership_updated_by?: string | null;
          membership_note?: string | null;
          public_contact_phone?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          business_name?: string | null;
          business_license?: string | null;
          certification_status?: CertificationStatus;
          membership_level?: string;
          membership_expires_at?: string | null;
          client_count?: number;
          survey_count?: number;
          invite_code?: string | null;
          intro_personal?: string | null;
          intro_company?: string | null;
          company_name?: string | null;
          digital_avatar_image_url?: string | null;
          digital_persona_video_url?: string | null;
          digital_persona_source_platform?: string | null;
          digital_persona_source_asset_id?: string | null;
          digital_persona_playback_url?: string | null;
          digital_persona_format?: string | null;
          digital_persona_status?: string | null;
          digital_persona_verified_at?: string | null;
          digital_persona_last_error?: string | null;
          tagline?: string | null;
          credentials?: string[] | null;
          partner_phone?: string | null;
          partner_card_status?: string | null;
          partner_card_public_url?: string | null;
          partner_card_slug?: string | null;
          partner_card_display_name?: string | null;
          partner_card_avatar_url?: string | null;
          partner_card_company_name?: string | null;
          partner_card_updated_at?: string | null;
          partner_card_synced_at?: string | null;
          partner_card_error?: string | null;
          featured_product_ids?: string[];
          is_example?: boolean;
          knowledge_index_id?: string | null;
          knowledge_index_status?: string | null;
          knowledge_model?: string | null;
          knowledge_system_prompt?: string | null;
          knowledge_category_id?: string | null;
          public_qa_enabled?: boolean;
          public_qa_welcome_message?: string | null;
          public_qa_lead_capture_mode?: string;
          short_code?: string | null;
          submitted_at?: string | null;
          reviewed_at?: string | null;
          reviewed_by?: string | null;
          review_note?: string;
          membership_enforcement_mode?: string;
          seat_limit_override?: number | null;
          client_limit_override?: number | null;
          membership_updated_at?: string | null;
          membership_updated_by?: string | null;
          membership_note?: string | null;
          public_contact_phone?: string | null;
          created_at?: string;
          updated_at?: string;
        };
      };
      membership_plans: {
        Row: {
          code: string;
          display_name: string;
          sort_order: number;
          manager_seat_limit: number;
          client_limit: number;
          ai_insight_monthly_limit: number | null;
          knowledge_doc_limit_per_manager: number;
          enterprise_center_enabled: boolean;
          shop_live_enabled: boolean;
          hard_enforce_numeric_limits: boolean;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          code: string;
          display_name: string;
          sort_order: number;
          manager_seat_limit: number;
          client_limit: number;
          ai_insight_monthly_limit?: number | null;
          knowledge_doc_limit_per_manager: number;
          enterprise_center_enabled?: boolean;
          shop_live_enabled?: boolean;
          hard_enforce_numeric_limits?: boolean;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          code?: string;
          display_name?: string;
          sort_order?: number;
          manager_seat_limit?: number;
          client_limit?: number;
          ai_insight_monthly_limit?: number | null;
          knowledge_doc_limit_per_manager?: number;
          enterprise_center_enabled?: boolean;
          shop_live_enabled?: boolean;
          hard_enforce_numeric_limits?: boolean;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
      };
      membership_contact_leads: {
        Row: {
          id: string;
          desired_plan_code: string | null;
          name: string;
          phone: string;
          company_name: string;
          job_title: string | null;
          submitted_by: string | null;
          status: string;
          admin_note: string | null;
          handled_by: string | null;
          handled_at: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          desired_plan_code?: string | null;
          name: string;
          phone: string;
          company_name: string;
          job_title?: string | null;
          submitted_by?: string | null;
          status?: string;
          admin_note?: string | null;
          handled_by?: string | null;
          handled_at?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          desired_plan_code?: string | null;
          name?: string;
          phone?: string;
          company_name?: string;
          job_title?: string | null;
          submitted_by?: string | null;
          status?: string;
          admin_note?: string | null;
          handled_by?: string | null;
          handled_at?: string | null;
          created_at?: string;
          updated_at?: string;
        };
      };
      membership_usage_events: {
        Row: {
          id: string;
          root_manager_id: string;
          actor_manager_id: string;
          metric: string;
          period_month: string;
          status: string;
          resource_id: string | null;
          metadata: Json;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          root_manager_id: string;
          actor_manager_id: string;
          metric: string;
          period_month: string;
          status?: string;
          resource_id?: string | null;
          metadata?: Json;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          root_manager_id?: string;
          actor_manager_id?: string;
          metric?: string;
          period_month?: string;
          status?: string;
          resource_id?: string | null;
          metadata?: Json;
          created_at?: string;
          updated_at?: string;
        };
      };
      manager_courses: {
        Row: {
          id: string;
          manager_id: string;
          title: string;
          cover_image_url: string | null;
          description: string | null;
          duration_minutes: number | null;
          chapters: Json;
          is_published: boolean;
          sort_weight: number;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          manager_id: string;
          title: string;
          cover_image_url?: string | null;
          description?: string | null;
          duration_minutes?: number | null;
          chapters?: Json;
          is_published?: boolean;
          sort_weight?: number;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          manager_id?: string;
          title?: string;
          cover_image_url?: string | null;
          description?: string | null;
          duration_minutes?: number | null;
          chapters?: Json;
          is_published?: boolean;
          sort_weight?: number;
          created_at?: string;
          updated_at?: string;
        };
      };
      manager_knowledge_documents: {
        Row: {
          id: string;
          manager_id: string;
          title: string;
          storage_url: string | null;
          storage_key: string | null;
          file_size_bytes: number | null;
          mime_type: string | null;
          backend: 'kqa' | 'bailian';
          external_file_id: string | null;
          external_index_id: string | null;
          status: 'uploading' | 'indexing' | 'parsing' | 'ready' | 'failed';
          error_message: string | null;
          content_text: string | null;
          source: 'user_upload' | 'auto_sync' | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          manager_id: string;
          title: string;
          storage_url?: string | null;
          storage_key?: string | null;
          file_size_bytes?: number | null;
          mime_type?: string | null;
          backend: 'kqa' | 'bailian';
          external_file_id?: string | null;
          external_index_id?: string | null;
          status?: 'uploading' | 'indexing' | 'parsing' | 'ready' | 'failed';
          error_message?: string | null;
          content_text?: string | null;
          source?: 'user_upload' | 'auto_sync' | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          manager_id?: string;
          title?: string;
          storage_url?: string | null;
          storage_key?: string | null;
          file_size_bytes?: number | null;
          mime_type?: string | null;
          backend?: 'kqa' | 'bailian';
          external_file_id?: string | null;
          external_index_id?: string | null;
          status?: 'uploading' | 'indexing' | 'parsing' | 'ready' | 'failed';
          error_message?: string | null;
          content_text?: string | null;
          source?: 'user_upload' | 'auto_sync' | null;
          created_at?: string;
          updated_at?: string;
        };
      };
      health_records: {
        Row: {
          id: string;
          user_id: string;
          name: string;
          relationship: string;
          gender: string | null;
          birth_date: string | null;
          height: number | null;
          weight: number | null;
          blood_type: string | null;
          medical_history: string | null;
          allergy_history: string | null;
          surgery_history: string | null;
          medication_history: string | null;
          is_default: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id: string;
          name: string;
          relationship?: string;
          gender?: string | null;
          birth_date?: string | null;
          height?: number | null;
          weight?: number | null;
          blood_type?: string | null;
          medical_history?: string | null;
          allergy_history?: string | null;
          surgery_history?: string | null;
          medication_history?: string | null;
          is_default?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          name?: string;
          relationship?: string;
          gender?: string | null;
          birth_date?: string | null;
          height?: number | null;
          weight?: number | null;
          blood_type?: string | null;
          medical_history?: string | null;
          allergy_history?: string | null;
          surgery_history?: string | null;
          medication_history?: string | null;
          is_default?: boolean;
          created_at?: string;
          updated_at?: string;
        };
      };
      vital_signs: {
        Row: {
          id: string;
          record_id: string;
          heart_rate: number | null;
          systolic_pressure: number | null;
          diastolic_pressure: number | null;
          blood_sugar: number | null;
          temperature: number | null;
          weight: number | null;
          recorded_at: string;
          notes: string | null;
        };
        Insert: {
          id?: string;
          record_id: string;
          heart_rate?: number | null;
          systolic_pressure?: number | null;
          diastolic_pressure?: number | null;
          blood_sugar?: number | null;
          temperature?: number | null;
          weight?: number | null;
          recorded_at?: string;
          notes?: string | null;
        };
        Update: {
          id?: string;
          record_id?: string;
          heart_rate?: number | null;
          systolic_pressure?: number | null;
          diastolic_pressure?: number | null;
          blood_sugar?: number | null;
          temperature?: number | null;
          weight?: number | null;
          recorded_at?: string;
          notes?: string | null;
        };
      };
      ai_agents: {
        Row: {
          id: string;
          name: string;
          slug: string;
          icon: string | null;
          description: string | null;
          welcome_message: string | null;
          system_prompt: string | null;
          is_enabled: boolean;
          display_order: number;
          conversation_count: number;
          user_count: number;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          name: string;
          slug: string;
          icon?: string | null;
          description?: string | null;
          welcome_message?: string | null;
          system_prompt?: string | null;
          is_enabled?: boolean;
          display_order?: number;
          conversation_count?: number;
          user_count?: number;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          name?: string;
          slug?: string;
          icon?: string | null;
          description?: string | null;
          welcome_message?: string | null;
          system_prompt?: string | null;
          is_enabled?: boolean;
          display_order?: number;
          conversation_count?: number;
          user_count?: number;
          created_at?: string;
          updated_at?: string;
        };
      };
      survey_creator_agent: {
        Row: {
          id: string;
          singleton: string;
          system_prompt: string;
          text_model: string;
          vision_model: string;
          temperature: number;
          max_tokens: number;
          enabled: boolean;
          updated_at: string;
          updated_by: string | null;
        };
        Insert: {
          id?: string;
          singleton?: string;
          system_prompt?: string;
          text_model?: string;
          vision_model?: string;
          temperature?: number;
          max_tokens?: number;
          enabled?: boolean;
          updated_at?: string;
          updated_by?: string | null;
        };
        Update: {
          id?: string;
          singleton?: string;
          system_prompt?: string;
          text_model?: string;
          vision_model?: string;
          temperature?: number;
          max_tokens?: number;
          enabled?: boolean;
          updated_at?: string;
          updated_by?: string | null;
        };
      };
      conversations: {
        Row: {
          id: string;
          user_id: string;
          agent_id: string | null;
          record_id: string | null;
          title: string | null;
          status: string;
          message_count: number;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id: string;
          agent_id?: string | null;
          record_id?: string | null;
          title?: string | null;
          status?: string;
          message_count?: number;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          agent_id?: string | null;
          record_id?: string | null;
          title?: string | null;
          status?: string;
          message_count?: number;
          created_at?: string;
          updated_at?: string;
        };
      };
      messages: {
        Row: {
          id: string;
          conversation_id: string;
          role: string;
          content: string;
          is_flagged: boolean;
          created_at: string;
        };
        Insert: {
          id?: string;
          conversation_id: string;
          role: string;
          content: string;
          is_flagged?: boolean;
          created_at?: string;
        };
        Update: {
          id?: string;
          conversation_id?: string;
          role?: string;
          content?: string;
          is_flagged?: boolean;
          created_at?: string;
        };
      };
      medical_reports: {
        Row: {
          id: string;
          user_id: string;
          record_id: string | null;
          title: string;
          hospital: string | null;
          report_date: string | null;
          file_url: string;
          file_type: string;
          file_size: number | null;
          status: string;
          total_items: number | null;
          abnormal_items: number | null;
          ai_summary: string | null;
          parsed_data: Json;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id: string;
          record_id?: string | null;
          title?: string;
          hospital?: string | null;
          report_date?: string | null;
          file_url: string;
          file_type?: string;
          file_size?: number | null;
          status?: string;
          total_items?: number | null;
          abnormal_items?: number | null;
          ai_summary?: string | null;
          parsed_data?: Json;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          record_id?: string | null;
          title?: string;
          hospital?: string | null;
          report_date?: string | null;
          file_url?: string;
          file_type?: string;
          file_size?: number | null;
          status?: string;
          total_items?: number | null;
          abnormal_items?: number | null;
          ai_summary?: string | null;
          parsed_data?: Json;
          created_at?: string;
          updated_at?: string;
        };
      };
      surveys: {
        Row: {
          id: string;
          manager_id: string;
          title: string;
          description: string | null;
          status: SurveyStatus;
          is_template: boolean;
          share_code: string | null;
          response_count: number;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          manager_id: string;
          title: string;
          description?: string | null;
          status?: SurveyStatus;
          is_template?: boolean;
          share_code?: string | null;
          response_count?: number;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          manager_id?: string;
          title?: string;
          description?: string | null;
          status?: SurveyStatus;
          is_template?: boolean;
          share_code?: string | null;
          response_count?: number;
          created_at?: string;
          updated_at?: string;
        };
      };
      survey_questions: {
        Row: {
          id: string;
          survey_id: string;
          question_type: string;
          title: string;
          description: string | null;
          options: Json | null;
          is_required: boolean;
          display_order: number;
          created_at: string;
        };
        Insert: {
          id?: string;
          survey_id: string;
          question_type?: string;
          title: string;
          description?: string | null;
          options?: Json | null;
          is_required?: boolean;
          display_order?: number;
          created_at?: string;
        };
        Update: {
          id?: string;
          survey_id?: string;
          question_type?: string;
          title?: string;
          description?: string | null;
          options?: Json | null;
          is_required?: boolean;
          display_order?: number;
          created_at?: string;
        };
      };
      survey_responses: {
        Row: {
          id: string;
          survey_id: string;
          respondent_id: string | null;
          respondent_name: string | null;
          respondent_phone: string | null;
          answers: Json;
          submitted_at: string;
        };
        Insert: {
          id?: string;
          survey_id: string;
          respondent_id?: string | null;
          respondent_name?: string | null;
          respondent_phone?: string | null;
          answers?: Json;
          submitted_at?: string;
        };
        Update: {
          id?: string;
          survey_id?: string;
          respondent_id?: string | null;
          respondent_name?: string | null;
          respondent_phone?: string | null;
          answers?: Json;
          submitted_at?: string;
        };
      };
      survey_assignments: {
        Row: {
          id: string;
          survey_id: string;
          client_user_id: string;
          manager_id: string;
          sent_at: string;
          completed_at: string | null;
          response_id: string | null;
        };
        Insert: {
          id?: string;
          survey_id: string;
          client_user_id: string;
          manager_id: string;
          sent_at?: string;
          completed_at?: string | null;
          response_id?: string | null;
        };
        Update: {
          id?: string;
          survey_id?: string;
          client_user_id?: string;
          manager_id?: string;
          sent_at?: string;
          completed_at?: string | null;
          response_id?: string | null;
        };
      };
      notifications: {
        Row: {
          id: string;
          user_id: string;
          type: string;
          title: string;
          body: string;
          data: Json;
          read_at: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          user_id: string;
          type: string;
          title: string;
          body?: string;
          data?: Json;
          read_at?: string | null;
          created_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          type?: string;
          title?: string;
          body?: string;
          data?: Json;
          read_at?: string | null;
          created_at?: string;
        };
      };
      operation_logs: {
        Row: {
          id: string;
          user_id: string;
          action: string;
          detail: string | null;
          module: string;
          metadata: Json;
          created_at: string;
          enterprise_root_id: string | null;
          actor_name_snapshot: string | null;
        };
        Insert: {
          id?: string;
          user_id: string;
          action: string;
          detail?: string | null;
          module: string;
          metadata?: Json;
          created_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          action?: string;
          detail?: string | null;
          module?: string;
          metadata?: Json;
          created_at?: string;
        };
      };
      client_relations: {
        Row: {
          id: string;
          manager_id: string;
          client_id: string;
          status: string;
          notes: string | null;
          last_contact_at: string | null;
          health_portrait: string;
          health_portrait_updated_at: string | null;
          follow_up_suggestion: string;
          follow_up_suggestion_updated_at: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          manager_id: string;
          client_id: string;
          status?: string;
          notes?: string | null;
          last_contact_at?: string | null;
          health_portrait?: string;
          health_portrait_updated_at?: string | null;
          follow_up_suggestion?: string;
          follow_up_suggestion_updated_at?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          manager_id?: string;
          client_id?: string;
          status?: string;
          notes?: string | null;
          last_contact_at?: string | null;
          health_portrait?: string;
          health_portrait_updated_at?: string | null;
          follow_up_suggestion?: string;
          follow_up_suggestion_updated_at?: string | null;
          created_at?: string;
          updated_at?: string;
        };
      };
      custom_models: {
        Row: {
          id: string;
          name: string;
          provider: string;
          model_id: string;
          api_key: string;
          base_url: string;
          is_vision: boolean;
          is_enabled: boolean;
          description: string;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          name: string;
          provider: string;
          model_id: string;
          api_key?: string;
          base_url?: string;
          is_vision?: boolean;
          is_enabled?: boolean;
          description?: string;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          name?: string;
          provider?: string;
          model_id?: string;
          api_key?: string;
          base_url?: string;
          is_vision?: boolean;
          is_enabled?: boolean;
          description?: string;
          created_at?: string;
          updated_at?: string;
        };
      };
      client_tags: {
        Row: {
          id: string;
          manager_id: string;
          name: string;
          color: string;
          created_at: string;
        };
        Insert: {
          id?: string;
          manager_id: string;
          name: string;
          color?: string;
          created_at?: string;
        };
        Update: {
          id?: string;
          manager_id?: string;
          name?: string;
          color?: string;
          created_at?: string;
        };
      };
      client_tag_relations: {
        Row: {
          id: string;
          client_relation_id: string;
          tag_id: string;
          created_at: string;
        };
        Insert: {
          id?: string;
          client_relation_id: string;
          tag_id: string;
          created_at?: string;
        };
        Update: {
          id?: string;
          client_relation_id?: string;
          tag_id?: string;
          created_at?: string;
        };
      };
      follow_up_records: {
        Row: {
          id: string;
          client_relation_id: string;
          content: string;
          follow_up_type: string | null;
          next_follow_up_at: string | null;
          reminder: boolean;
          reminder_wecom: boolean;
          reminded_at: string | null;
          created_by: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          client_relation_id: string;
          content: string;
          follow_up_type?: string | null;
          next_follow_up_at?: string | null;
          reminder?: boolean;
          reminder_wecom?: boolean;
          reminded_at?: string | null;
          created_by?: string | null;
          created_at?: string;
        };
        Update: {
          id?: string;
          client_relation_id?: string;
          content?: string;
          follow_up_type?: string | null;
          next_follow_up_at?: string | null;
          reminder?: boolean;
          reminder_wecom?: boolean;
          reminded_at?: string | null;
          created_by?: string | null;
          created_at?: string;
        };
      };
      record_authorizations: {
        Row: {
          id: string;
          record_id: string;
          manager_id: string;
          granted_at: string;
          expires_at: string | null;
          is_active: boolean;
        };
        Insert: {
          id?: string;
          record_id: string;
          manager_id: string;
          granted_at?: string;
          expires_at?: string | null;
          is_active?: boolean;
        };
        Update: {
          id?: string;
          record_id?: string;
          manager_id?: string;
          granted_at?: string;
          expires_at?: string | null;
          is_active?: boolean;
        };
      };
      mood_logs: {
        Row: {
          id: string;
          user_id: string;
          mood_level: number;
          emotions: string[];
          trigger: string;
          notes: string;
          activity_type: string;
          activity_minutes: number;
          logged_at: string;
          created_at: string;
        };
        Insert: {
          id?: string;
          user_id: string;
          mood_level: number;
          emotions?: string[];
          trigger?: string;
          notes?: string;
          activity_type?: string;
          activity_minutes?: number;
          logged_at?: string;
          created_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          mood_level?: number;
          emotions?: string[];
          trigger?: string;
          notes?: string;
          activity_type?: string;
          activity_minutes?: number;
          logged_at?: string;
          created_at?: string;
        };
      };
      mood_goals: {
        Row: {
          id: string;
          user_id: string;
          goal_type: string;
          target_value: number;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id: string;
          goal_type?: string;
          target_value?: number;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          goal_type?: string;
          target_value?: number;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
      };
      report_comparisons: {
        Row: {
          id: string;
          user_id: string;
          report_older_id: string;
          report_newer_id: string;
          status: 'pending' | 'generating' | 'ready' | 'failed';
          summary: string;
          improvement_score: number | null;
          deltas: Json;
          highlights: Json;
          ai_comment: string;
          model_used: string;
          error_message: string;
          generated_at: string | null;
          created_at: string;
        };
        Insert: {
          id?: string;
          user_id: string;
          report_older_id: string;
          report_newer_id: string;
          status?: 'pending' | 'generating' | 'ready' | 'failed';
          summary?: string;
          improvement_score?: number | null;
          deltas?: Json;
          highlights?: Json;
          ai_comment?: string;
          model_used?: string;
          error_message?: string;
          generated_at?: string | null;
          created_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          report_older_id?: string;
          report_newer_id?: string;
          status?: 'pending' | 'generating' | 'ready' | 'failed';
          summary?: string;
          improvement_score?: number | null;
          deltas?: Json;
          highlights?: Json;
          ai_comment?: string;
          model_used?: string;
          error_message?: string;
          generated_at?: string | null;
          created_at?: string;
        };
      };
      products: {
        Row: {
          id: string;
          source_type: 'platform' | 'manager';
          owner_manager_id: string | null;
          title: string;
          subtitle: string;
          description: string;
          cover_image_url: string;
          cover_images: Json;
          gallery_images: Json;
          category: string;
          tags: string[];
          status: 'draft' | 'pending_review' | 'rejected' | 'active' | 'archived';
          is_featured: boolean;
          sort_weight: number;
          sales_count: number;
          view_count: number;
          created_by: string;
          created_at: string;
          updated_at: string;
          submitted_at: string | null;
          reviewed_at: string | null;
          reviewed_by: string | null;
          review_note: string;
        };
        Insert: {
          id?: string;
          source_type: 'platform' | 'manager';
          owner_manager_id?: string | null;
          title: string;
          subtitle?: string;
          description?: string;
          cover_image_url?: string;
          cover_images?: Json;
          gallery_images?: Json;
          category?: string;
          tags?: string[];
          status?: 'draft' | 'pending_review' | 'rejected' | 'active' | 'archived';
          is_featured?: boolean;
          sort_weight?: number;
          sales_count?: number;
          view_count?: number;
          created_by: string;
          created_at?: string;
          updated_at?: string;
          submitted_at?: string | null;
          reviewed_at?: string | null;
          reviewed_by?: string | null;
          review_note?: string;
        };
        Update: {
          id?: string;
          source_type?: 'platform' | 'manager';
          owner_manager_id?: string | null;
          title?: string;
          subtitle?: string;
          description?: string;
          cover_image_url?: string;
          cover_images?: Json;
          gallery_images?: Json;
          category?: string;
          tags?: string[];
          status?: 'draft' | 'pending_review' | 'rejected' | 'active' | 'archived';
          is_featured?: boolean;
          sort_weight?: number;
          sales_count?: number;
          view_count?: number;
          created_by?: string;
          created_at?: string;
          updated_at?: string;
          submitted_at?: string | null;
          reviewed_at?: string | null;
          reviewed_by?: string | null;
          review_note?: string;
        };
      };
      product_skus: {
        Row: {
          id: string;
          product_id: string;
          sku_code: string;
          price_cents: number;
          original_price_cents: number | null;
          stock: number;
          attributes: Json;
          is_default: boolean;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          product_id: string;
          sku_code?: string;
          price_cents?: number;
          original_price_cents?: number | null;
          stock?: number;
          attributes?: Json;
          is_default?: boolean;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          product_id?: string;
          sku_code?: string;
          price_cents?: number;
          original_price_cents?: number | null;
          stock?: number;
          attributes?: Json;
          is_default?: boolean;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
      };
      product_image_generations: {
        Row: {
          id: string;
          product_id: string | null;
          user_id: string;
          source_image_url: string;
          prompt: string;
          preset_key: string;
          candidate_urls: Json;
          selected_url: string;
          selected_urls: Json;
          target_type: 'cover' | 'gallery' | 'detail';
          style_variants: Json;
          count: number;
          status: 'pending' | 'generating' | 'ready' | 'failed';
          model_used: string;
          error_message: string;
          created_at: string;
          completed_at: string | null;
        };
        Insert: {
          id?: string;
          product_id?: string | null;
          user_id: string;
          source_image_url: string;
          prompt?: string;
          preset_key?: string;
          candidate_urls?: Json;
          selected_url?: string;
          selected_urls?: Json;
          target_type?: 'cover' | 'gallery' | 'detail';
          style_variants?: Json;
          count?: number;
          status?: 'pending' | 'generating' | 'ready' | 'failed';
          model_used?: string;
          error_message?: string;
          created_at?: string;
          completed_at?: string | null;
        };
        Update: {
          id?: string;
          product_id?: string | null;
          user_id?: string;
          source_image_url?: string;
          prompt?: string;
          preset_key?: string;
          candidate_urls?: Json;
          selected_url?: string;
          selected_urls?: Json;
          target_type?: 'cover' | 'gallery' | 'detail';
          style_variants?: Json;
          count?: number;
          status?: 'pending' | 'generating' | 'ready' | 'failed';
          model_used?: string;
          error_message?: string;
          created_at?: string;
          completed_at?: string | null;
        };
      };
      product_share_grants: {
        Row: {
          id: string;
          product_id: string;
          manager_id: string;
          client_id: string | null;
          audience: 'specific' | 'all_clients' | 'tag';
          tag_id: string | null;
          share_token: string | null;
          note: string;
          created_at: string;
          expires_at: string | null;
          revoked_at: string | null;
        };
        Insert: {
          id?: string;
          product_id: string;
          manager_id: string;
          client_id?: string | null;
          audience?: 'specific' | 'all_clients' | 'tag';
          tag_id?: string | null;
          share_token?: string | null;
          note?: string;
          created_at?: string;
          expires_at?: string | null;
          revoked_at?: string | null;
        };
        Update: {
          id?: string;
          product_id?: string;
          manager_id?: string;
          client_id?: string | null;
          audience?: 'specific' | 'all_clients' | 'tag';
          tag_id?: string | null;
          share_token?: string | null;
          note?: string;
          created_at?: string;
          expires_at?: string | null;
          revoked_at?: string | null;
        };
      };
      avatar_profiles_cache: {
        Row: {
          id: string;
          external_avatar_id: string;
          display_name: string;
          avatar_thumb_url: string;
          voice_id: string;
          voice_name: string;
          voice_sample_url: string;
          capability_tags: Json;
          is_available: boolean;
          last_synced_at: string;
          created_at: string;
        };
        Insert: {
          id?: string;
          external_avatar_id: string;
          display_name?: string;
          avatar_thumb_url?: string;
          voice_id?: string;
          voice_name?: string;
          voice_sample_url?: string;
          capability_tags?: Json;
          is_available?: boolean;
          last_synced_at?: string;
          created_at?: string;
        };
        Update: {
          id?: string;
          external_avatar_id?: string;
          display_name?: string;
          avatar_thumb_url?: string;
          voice_id?: string;
          voice_name?: string;
          voice_sample_url?: string;
          capability_tags?: Json;
          is_available?: boolean;
          last_synced_at?: string;
          created_at?: string;
        };
      };
      orders: {
        Row: {
          id: string;
          out_trade_no: string;
          user_id: string;
          product_id: string | null;
          sku_id: string | null;
          product_title_snapshot: string;
          cover_image_snapshot: string;
          unit_price_cents: number;
          quantity: number;
          total_amount_cents: number;
          product_source_type_snapshot: 'platform' | 'manager';
          owner_manager_id_snapshot: string | null;
          status: 'pending' | 'paid' | 'cancelled' | 'closed' | 'refunding' | 'refunded';
          preferred_payment_method: 'wechat' | 'alipay' | null;
          payment_method: 'wechat' | 'alipay' | null;
          trade_no: string;
          paid_amount_cents: number | null;
          stock_decremented: boolean;
          manual_refund_required: boolean;
          refund_amount_cents: number | null;
          refund_reason: string;
          contact_name: string;
          contact_phone: string;
          shipping_province: string;
          shipping_city: string;
          shipping_district: string;
          shipping_address_detail: string;
          remark: string;
          created_at: string;
          updated_at: string;
          paid_at: string | null;
          cancelled_at: string | null;
          closed_at: string | null;
          refunded_at: string | null;
        };
        Insert: {
          id?: string;
          out_trade_no: string;
          user_id: string;
          product_id?: string | null;
          sku_id?: string | null;
          product_title_snapshot: string;
          cover_image_snapshot?: string;
          unit_price_cents: number;
          quantity: number;
          total_amount_cents: number;
          product_source_type_snapshot: 'platform' | 'manager';
          owner_manager_id_snapshot?: string | null;
          status?: 'pending' | 'paid' | 'cancelled' | 'closed' | 'refunding' | 'refunded';
          preferred_payment_method?: 'wechat' | 'alipay' | null;
          payment_method?: 'wechat' | 'alipay' | null;
          trade_no?: string;
          paid_amount_cents?: number | null;
          stock_decremented?: boolean;
          manual_refund_required?: boolean;
          refund_amount_cents?: number | null;
          refund_reason?: string;
          contact_name: string;
          contact_phone: string;
          shipping_province: string;
          shipping_city: string;
          shipping_district: string;
          shipping_address_detail: string;
          remark?: string;
          created_at?: string;
          updated_at?: string;
          paid_at?: string | null;
          cancelled_at?: string | null;
          closed_at?: string | null;
          refunded_at?: string | null;
        };
        Update: {
          id?: string;
          out_trade_no?: string;
          user_id?: string;
          product_id?: string | null;
          sku_id?: string | null;
          product_title_snapshot?: string;
          cover_image_snapshot?: string;
          unit_price_cents?: number;
          quantity?: number;
          total_amount_cents?: number;
          product_source_type_snapshot?: 'platform' | 'manager';
          owner_manager_id_snapshot?: string | null;
          status?: 'pending' | 'paid' | 'cancelled' | 'closed' | 'refunding' | 'refunded';
          preferred_payment_method?: 'wechat' | 'alipay' | null;
          payment_method?: 'wechat' | 'alipay' | null;
          trade_no?: string;
          paid_amount_cents?: number | null;
          stock_decremented?: boolean;
          manual_refund_required?: boolean;
          refund_amount_cents?: number | null;
          refund_reason?: string;
          contact_name?: string;
          contact_phone?: string;
          shipping_province?: string;
          shipping_city?: string;
          shipping_district?: string;
          shipping_address_detail?: string;
          remark?: string;
          created_at?: string;
          updated_at?: string;
          paid_at?: string | null;
          cancelled_at?: string | null;
          closed_at?: string | null;
          refunded_at?: string | null;
        };
      };
      diet_map_templates: {
        Row: {
          id: string;
          map_key: string;
          title: string;
          description: string;
          status: 'draft' | 'published' | 'archived';
          questions: Json;
          scoring: Json;
          report: Json;
          config_version: number;
          scoring_confirmed: boolean;
          scoring_confirmed_by: string | null;
          scoring_confirmed_at: string | null;
          created_by: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          map_key: string;
          title?: string;
          description?: string;
          status?: 'draft' | 'published' | 'archived';
          questions?: Json;
          scoring?: Json;
          report?: Json;
          config_version?: number;
          scoring_confirmed?: boolean;
          scoring_confirmed_by?: string | null;
          scoring_confirmed_at?: string | null;
          created_by?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          map_key?: string;
          title?: string;
          description?: string;
          status?: 'draft' | 'published' | 'archived';
          questions?: Json;
          scoring?: Json;
          report?: Json;
          config_version?: number;
          scoring_confirmed?: boolean;
          scoring_confirmed_by?: string | null;
          scoring_confirmed_at?: string | null;
          updated_at?: string;
        };
      };
      diet_map_grants: {
        Row: {
          id: string;
          template_id: string;
          root_manager_id: string;
          is_enabled: boolean;
          granted_by: string | null;
          granted_at: string;
          notes: string;
        };
        Insert: {
          id?: string;
          template_id: string;
          root_manager_id: string;
          is_enabled?: boolean;
          granted_by?: string | null;
          granted_at?: string;
          notes?: string;
        };
        Update: {
          is_enabled?: boolean;
          granted_by?: string | null;
          granted_at?: string;
          notes?: string;
        };
      };
      diet_map_assessments: {
        Row: {
          id: string;
          template_id: string;
          config_version: number;
          user_id: string;
          record_id: string;
          manager_id: string | null;
          answers: Json;
          status: 'scored' | 'pending_config' | 'pending_tie';
          type_code: string;
          scores: Json;
          report_snapshot: Json;
          prefill_meta: Json;
          source_composition_id: string | null;
          submitted_at: string;
          created_at: string;
        };
        Insert: {
          id?: string;
          template_id: string;
          config_version?: number;
          user_id: string;
          record_id: string;
          manager_id?: string | null;
          answers?: Json;
          status?: 'scored' | 'pending_config' | 'pending_tie';
          type_code?: string;
          scores?: Json;
          report_snapshot?: Json;
          prefill_meta?: Json;
          source_composition_id?: string | null;
          submitted_at?: string;
          created_at?: string;
        };
        Update: {
          status?: 'scored' | 'pending_config' | 'pending_tie';
          type_code?: string;
          scores?: Json;
          report_snapshot?: Json;
          config_version?: number;
        };
      };
    };
    Views: {
      [_ in never]: never;
    };
    Functions: {
      create_share_snapshot: {
        Args: {
          p_message_source: string;
          p_message_id: string;
          p_snapshot_content: string;
          p_snapshot_summary?: string | null;
          p_conversation_id?: string | null;
          p_session_id?: string | null;
          p_user_id?: string | null;
          p_expires_hours?: number;
        };
        Returns: {
          public_token: string;
        }[];
      };
      get_share_snapshot: {
        Args: {
          p_public_token: string;
        };
        Returns: {
          message_source: string;
          snapshot_content: string;
          snapshot_summary: string | null;
          manager_name: string | null;
          poster_url: string | null;
          expires_at: string;
          is_revoked: boolean;
        }[];
      };
      update_snapshot_poster: {
        Args: {
          p_public_token: string;
          p_poster_url: string;
        };
        Returns: undefined;
      };
      save_survey_questions: {
        Args: {
          p_survey_id: string;
          p_questions: Json;
        };
        Returns: Database['public']['Tables']['survey_questions']['Row'][];
      };
      assign_survey_to_clients: {
        Args: {
          p_survey_id: string;
          p_client_user_ids: string[];
        };
        Returns: {
          assignedCount: number;
          skippedCount: number;
          notifiedCount: number;
        };
      };
      mark_notification_read: {
        Args: {
          p_notification_id: string;
        };
        Returns: boolean;
      };
      mark_all_notifications_read: {
        Args: Record<PropertyKey, never>;
        Returns: number;
      };
      transfer_medical_report_record: {
        Args: {
          p_report_id: string;
          p_target_record_id: string;
        };
        Returns: Database['public']['Tables']['medical_reports']['Row'];
      };
      admin_review_product: {
        Args: {
          p_id: string;
          p_action: 'approve' | 'reject';
          p_note?: string;
        };
        Returns: Database['public']['Tables']['products']['Row'];
      };
      admin_create_product: {
        Args: {
          p_title: string;
          p_subtitle?: string;
          p_description?: string;
          p_cover_image_url?: string;
          p_gallery_images?: Json;
          p_category?: string;
          p_tags?: string[];
          p_status?: 'draft' | 'active' | 'archived';
          p_is_featured?: boolean;
          p_sort_weight?: number;
          p_cover_images?: Json | null;
        };
        Returns: Database['public']['Tables']['products']['Row'];
      };
      admin_update_product: {
        Args: {
          p_id: string;
          p_patch: Json;
        };
        Returns: Database['public']['Tables']['products']['Row'];
      };
      admin_update_default_product_sku: {
        Args: {
          p_product_id: string;
          p_price_cents: number;
          p_original_price_cents: number | null;
          p_stock: number;
        };
        Returns: Database['public']['Tables']['product_skus']['Row'];
      };
      get_active_product_detail_for_link: {
        Args: {
          p_product_id: string;
        };
        Returns: Json;
      };
      create_shop_order: {
        Args: {
          p_out_trade_no: string;
          p_product_id: string;
          p_quantity: number;
          p_preferred_payment_method: 'wechat' | 'alipay';
          p_contact_name: string;
          p_contact_phone: string;
          p_province: string;
          p_city: string;
          p_district: string;
          p_address_detail: string;
          p_remark?: string;
        };
        Returns: Database['public']['Tables']['orders']['Row'];
      };
      user_cancel_shop_order: {
        Args: {
          p_out_trade_no: string;
        };
        Returns: Database['public']['Tables']['orders']['Row'];
      };
      mark_order_paid_from_gateway: {
        Args: {
          p_out_trade_no: string;
          p_trade_no: string;
          p_paid_amount: number;
          p_payment_method: 'wechat' | 'alipay' | '';
        };
        Returns: Database['public']['Tables']['orders']['Row'];
      };
      mark_order_refunded_from_gateway: {
        Args: {
          p_out_trade_no: string;
          p_refund_amount: number;
          p_reason: string;
        };
        Returns: Database['public']['Tables']['orders']['Row'] | null;
      };
      get_public_manager_card: {
        Args: {
          p_manager_id: string;
        };
        Returns: Json;
      };
      get_public_manager_course: {
        Args: {
          p_manager_id: string;
          p_course_id: string;
        };
        Returns: Json;
      };
      get_my_bound_manager_card: {
        Args: Record<PropertyKey, never>;
        Returns: Json;
      };
      bind_manager_from_card: {
        Args: {
          p_manager_id: string;
          p_invite_code: string;
        };
        Returns: Json;
      };
      bind_manager_by_invite_code: {
        Args: {
          p_invite_code: string;
        };
        Returns: Json;
      };
      unbind_my_manager: {
        Args: Record<PropertyKey, never>;
        Returns: Json;
      };
      get_public_qa_config: {
        Args: {
          p_manager_id: string;
        };
        Returns: Json;
      };
      submit_public_qa_lead: {
        Args: {
          p_manager_id: string;
          p_visitor_token: string;
          p_phone: string;
          p_name: string | null;
        };
        Returns: Json;
      };
      list_my_public_qa_sessions: {
        Args: {
          p_limit?: number;
          p_offset?: number;
        };
        Returns: Json;
      };
      get_my_public_qa_session_messages: {
        Args: {
          p_session_id: string;
        };
        Returns: Json;
      };
      get_enterprise_root_manager_id: {
        Args: {
          uid: string;
        };
        Returns: string | null;
      };
      is_enterprise_admin: {
        Args: {
          uid: string;
        };
        Returns: boolean;
      };
      is_enterprise_member_for_admin: {
        Args: {
          member_manager_id: string;
          uid: string;
        };
        Returns: boolean;
      };
      get_enterprise_clients_with_owner: {
        Args: {
          p_limit?: number;
          p_offset?: number;
          p_search?: string | null;
          p_owner_manager_id?: string | null;
        };
        Returns: {
          relation_id: string;
          client_id: string;
          status: string;
          notes: string | null;
          last_contact_at: string | null;
          relation_created_at: string;
          nickname: string | null;
          phone: string | null;
          avatar_url: string | null;
          privacy_settings: Json | null;
          owner_manager_id: string;
          owner_manager_nickname: string | null;
          owner_manager_phone: string | null;
          owner_sub_role: string;
          owner_is_disabled: boolean;
          total_count: number;
        }[];
      };
      get_manager_clients: {
        Args: {
          p_manager_id: string;
        };
        Returns: {
          relation_id: string;
          client_id: string;
          status: string;
          notes: string | null;
          last_contact_at: string | null;
          relation_created_at: string;
          nickname: string | null;
          phone: string | null;
          avatar_url: string | null;
          privacy_settings: Json | null;
        }[];
      };
      can_manager_view_client_category: {
        Args: {
          p_client_id: string;
          p_category: string;
        };
        Returns: boolean;
      };
      get_manager_knowledge_settings: {
        Args: {
          p_manager_id?: string | null;
        };
        Returns: Json;
      };
      transfer_manager_clients: {
        Args: {
          p_from_manager_id: string;
          p_to_manager_id: string;
        };
        Returns: number;
      };
      create_manager_client: {
        Args: {
          p_nickname: string;
          p_phone?: string | null;
          p_notes?: string | null;
        };
        Returns: string;
      };
      update_manager_knowledge_settings: {
        Args: {
          p_model: string;
          p_system_prompt: string;
        };
        Returns: Json;
      };
      update_manager_knowledge_settings_for_manager: {
        Args: {
          p_manager_id: string;
          p_model: string;
          p_system_prompt: string;
        };
        Returns: Json;
      };
      get_manager_membership_entitlements: {
        Args: {
          p_manager_id: string;
        };
        Returns: {
          root_manager_id: string;
          plan_code: string;
          plan_display_name: string;
          enforcement_mode: string;
          is_legacy_unlimited: boolean;
          hard_enforce_numeric_limits: boolean;
          effective_seat_limit: number;
          effective_client_limit: number;
          ai_insight_monthly_limit: number | null;
          knowledge_doc_limit_per_manager: number;
          enterprise_center_enabled: boolean;
          shop_live_enabled: boolean;
          current_seat_count: number;
          current_client_count: number;
          current_ai_insight_used: number;
        }[];
      };
      admin_update_manager_membership: {
        Args: {
          p_manager_id: string;
          p_membership_level: string;
          p_enforcement_mode: string;
          p_seat_limit_override: number | null;
          p_client_limit_override: number | null;
          p_note: string | null;
        };
        Returns: undefined;
      };
      submit_membership_contact_lead: {
        Args: {
          p_desired_plan_code: string | null;
          p_name: string;
          p_phone: string;
          p_company_name: string;
          p_job_title: string | null;
        };
        Returns: undefined;
      };
      admin_list_membership_contact_leads: {
        Args: {
          p_status?: string | null;
          p_limit?: number;
          p_offset?: number;
        };
        Returns: {
          id: string;
          desired_plan_code: string | null;
          name: string;
          phone: string;
          company_name: string;
          job_title: string | null;
          status: string;
          admin_note: string | null;
          handled_by: string | null;
          handled_at: string | null;
          created_at: string;
        }[];
      };
      admin_get_landing_conversion_stats: {
        Args: {
          p_from: string;
          p_to: string;
        };
        Returns: Json;
      };
      admin_update_membership_contact_lead_status: {
        Args: {
          p_lead_id: string;
          p_status: string;
          p_admin_note: string | null;
        };
        Returns: undefined;
      };
      reserve_membership_ai_insight_usage: {
        Args: {
          p_actor_manager_id: string;
        };
        Returns: string;
      };
      finalize_membership_usage_event: {
        Args: {
          p_event_id: string;
          p_status: string;
        };
        Returns: undefined;
      };
      update_my_privacy_setting: {
        Args: {
          p_user_id: string;
          p_key: string;
          p_enabled: boolean;
        };
        Returns: Json;
      };
      update_my_notification_setting: {
        Args: {
          p_user_id: string;
          p_key: string;
          p_enabled: boolean;
        };
        Returns: Json;
      };
      get_manager_operation_logs: {
        Args: {
          p_module?: string | null;
          p_limit?: number;
          p_before_created_at?: string | null;
          p_before_id?: string | null;
        };
        Returns: Json;
      };
      validate_diet_map_config: {
        Args: {
          p_template_id: string;
        };
        Returns: Json;
      };
      publish_diet_map_template: {
        Args: {
          p_template_id: string;
        };
        Returns: Json;
      };
      set_diet_map_scoring_confirmed: {
        Args: {
          p_template_id: string;
          p_confirmed: boolean;
        };
        Returns: Json;
      };
      set_diet_map_grants: {
        Args: {
          p_template_id: string;
          p_root_manager_ids: string[];
          p_is_enabled?: boolean;
        };
        Returns: Json;
      };
      get_my_diet_map_access: {
        Args: {
          p_mp_manager?: string | null;
          p_record_id?: string | null;
        };
        Returns: Json;
      };
      submit_diet_map_assessment: {
        Args: {
          p_template_id: string;
          p_record_id: string;
          p_answers: Json;
          p_prefill_meta?: Json;
          p_source_composition_id?: string | null;
          p_mp_manager?: string | null;
        };
        Returns: Json;
      };
      admin_rescore_diet_map: {
        Args: {
          p_template_id: string;
          p_force?: boolean;
          p_limit?: number;
        };
        Returns: Json;
      };
      get_diet_map_coverage: {
        Args: {
          p_template_id?: string | null;
          p_root_manager_id?: string | null;
          p_cursor?: string | null;
          p_limit?: number;
        };
        Returns: Json;
      };
      send_diet_map_invite: {
        Args: {
          p_client_user_ids: string[];
          p_template_id?: string | null;
        };
        Returns: Json;
      };
    };
    Enums: {
      user_role: UserRole;
      certification_status: CertificationStatus;
      survey_status: SurveyStatus;
    };
    CompositeTypes: {
      [_ in never]: never;
    };
  };
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">;

type DefaultSchema = DatabaseWithoutInternals[Extract<
  keyof Database,
  "public"
>];

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R;
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
      DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] &
      DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R;
    }
    ? R
    : never
  : never;

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I;
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I;
    }
    ? I
    : never
  : never;

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U;
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U;
    }
    ? U
    : never
  : never;

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never;

// 导出常用类型
export type Profile = Tables<'profiles'>;
export type Manager = Tables<'managers'>;
export type HealthRecord = Tables<'health_records'>;
export type VitalSign = Tables<'vital_signs'>;
export type AIAgent = Tables<'ai_agents'>;
export type Conversation = Tables<'conversations'>;
export type Message = Tables<'messages'>;
export type Survey = Tables<'surveys'>;
export type SurveyQuestion = Tables<'survey_questions'>;
export type SurveyResponse = Tables<'survey_responses'>;
export type SurveyAssignmentRow = Tables<'survey_assignments'>;
export type NotificationRow = Tables<'notifications'>;
export type ClientRelation = Tables<'client_relations'>;
export type ClientTag = Tables<'client_tags'>;
export type FollowUpRecord = Tables<'follow_up_records'>;
export type RecordAuthorization = Tables<'record_authorizations'>;
export type ReportComparison = Tables<'report_comparisons'>;
export type Product = Tables<'products'>;
export type ProductStatus = Product['status'];
export type ProductSku = Tables<'product_skus'>;
export type ProductImageGeneration = Tables<'product_image_generations'>;
export type ProductShareGrant = Tables<'product_share_grants'>;
export type AvatarProfileCache = Tables<'avatar_profiles_cache'>;
export type Order = Tables<'orders'>;
export type OrderStatus = Order['status'];
export type OrderPaymentMethod = NonNullable<Order['payment_method']>;

