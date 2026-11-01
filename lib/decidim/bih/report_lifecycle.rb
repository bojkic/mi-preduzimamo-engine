# frozen_string_literal: true
module Decidim
  module Bih
    module ReportLifecycle
      class Forbidden < StandardError; end
      STAGES = %w(primljeno planirano proslijedjeno rijeseno zatvoreno).freeze
      TERMINAL = %w(rijeseno zatvoreno).freeze
      CLOSURE_BASES = {
        "rijeseno" => %w(sluzba_prijavila gradjanin_potvrdio tim_utvrdio nepotvrdjeno).freeze,
        "zatvoreno" => %w(duplikat van_nadleznosti upuceno_drugom_organu nejasno bez_odgovora prijedlog ostalo).freeze
      }.freeze
      TRANSITIONS = {
        "primljeno" => %w(planirano proslijedjeno rijeseno zatvoreno),
        "planirano" => %w(primljeno proslijedjeno rijeseno zatvoreno),
        "proslijedjeno" => %w(rijeseno zatvoreno),
        "rijeseno" => %w(primljeno planirano proslijedjeno),
        "zatvoreno" => %w(primljeno planirano proslijedjeno)
      }.transform_values(&:freeze).freeze
      module_function
      def allowed?(from, to) = TRANSITIONS.fetch(from.to_s, []).include?(to.to_s)
      def valid_closure?(stage, basis) = CLOSURE_BASES.fetch(stage.to_s, []).include?(basis.to_s)
      def reopen_stage(forwarded:, planned:)
        return "proslijedjeno" if forwarded
        planned ? "planirano" : "primljeno"
      end
      def notify?(from, to) = from == to ? nil : :status_update
      def from_legacy(status:, duplicate:, forwarded:, auto_closed:, rejection_basis: nil)
        return ["zatvoreno", "duplikat", false] if duplicate
        if %w(odbijeno zatvoreno).include?(status)
          return ["zatvoreno", "bez_odgovora", false] if auto_closed
          return ["zatvoreno", rejection_basis, false] if valid_closure?("zatvoreno", rejection_basis)
          return ["zatvoreno", "ostalo", true]
        end
        return ["rijeseno", valid_closure?("rijeseno", rejection_basis) ? rejection_basis : "nepotvrdjeno", false] if status == "rijeseno"
        return ["planirano", nil, false] if status == "planirano"
        return ["proslijedjeno", nil, false] if forwarded || status == "proslijedjeno"
        ["primljeno", nil, !%w(primljeno u_obradi).include?(status)]
      end
    end
  end
end
