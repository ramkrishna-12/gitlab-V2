#!/usr/bin/env bash
# Evidence that the restored instance really has the data. Run as root on the restore VM.
# Counts and flags only -- no secret value is printed.
set -euo pipefail
gitlab-rails runner '
puts "groups:   #{Group.order(:full_path).pluck(:full_path).inspect}"
puts "projects: #{Project.order(:id).pluck(:path_with_namespace).inspect}"
puts "users:    #{User.where(username: %w[alice-owner bob-maintainer carol-developer dave-reporter]).order(:username).pluck(:username, :admin).inspect}"
p = Project.find_by_full_path("company/team-web/web-sample")
puts "web-sample commits on main: #{p.repository.commit_count}; files: #{p.repository.ls_files("main").first(6).inspect}"
v = Ci::Variable.find_by(project_id: p.id, key: "DEMO_API_TOKEN")
puts "CI variable DEMO_API_TOKEN: masked=#{v.masked} protected=#{v.protected} decrypts_ok=#{v.value.to_s.length > 0}"
puts "protected branches: #{p.protected_branches.pluck(:name).inspect}"
s = ApplicationSetting.current
puts "settings: signup_enabled=#{s.signup_enabled} require_2fa=#{s.require_two_factor_authentication} default_project_visibility=#{s.default_project_visibility}"
'
