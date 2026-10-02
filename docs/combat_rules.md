# Combat rules and their tests

Every rule in docs/DESIGN.md "Core combat system" and the arena rules, with the test that proves it (backlog M2-01; the M2 gate asks that every combat rule has passing tests). `tests/test_combat_rules_doc.py` checks this table: each named test must exist, and a rule without a test must name the backlog item that adds one.

Column "Test" holds `file::test_name` (Godot tests under `game/test/`, Python tests under `tests/`); several are separated by `;`. Column "Planned" is used only while a rule has no test yet.

| Area | Rule | Test | Planned |
| --- | --- | --- | --- |
| Pacing | The global cooldown is 1.5 s | core/test_combat.gd::test_gcd_blocks_then_releases_after_1_5_s | |
| Pacing | Haste shortens the global cooldown to a floor of 0.75 s | core/test_combat.gd::test_haste_shortens_gcd_to_a_floor_of_0_75_s | |
| Pacing | Energy specs use a fixed 1.0 s global cooldown | core/test_combat.gd::test_energy_users_have_a_fixed_1_s_gcd_that_haste_does_not_shorten | |
| Pacing | A press inside the 400 ms spell queue window fires when the global cooldown ends; earlier presses are rejected | core/test_combat.gd::test_press_inside_queue_window_fires_on_first_tick_after_gcd; core/test_combat.gd::test_press_500ms_before_gcd_end_is_rejected_and_100ms_is_queued | |
| Pacing | The spell queue window is adjustable from 0 to 400 ms | client/test_settings.gd::test_the_spell_queue_window_and_auto_self_cast_are_each_players_own | |
| Pacing | Abilities are instant, cast or channeled, from data alone | core/test_combat.gd::test_instant_cast_and_channel_from_data_only | |
| Pacing | Moving cancels a cast unless the ability is castable while moving | core/test_combat.gd::test_moving_cancels_a_cast_unless_castable_while_moving | |
| Pacing | An interrupt ends the cast and locks that school for 3 to 4 s; other schools still work | core/test_combat.gd::test_interrupt_locks_the_school_and_other_schools_still_work; core/test_kits.gd::test_spellsever_locks_holy_for_4_s; test_combat_rule_data.py::test_interrupts_lock_a_school_for_3_to_4_s | |
| Pacing | Interrupt abilities have 15 to 24 s cooldowns; a healer's may be longer (kit template) | test_combat_rule_data.py::test_interrupt_cooldowns_are_15_to_24_s_and_healers_may_wait_longer | |
| Movement | Run speed is 7 m/s; backpedal is slower | core/test_movement_combat.gd::test_runs_7_metres_per_second_forward; core/test_movement_combat.gd::test_backpedal_is_slower | |
| Movement | Jumping goes up and lands | core/test_movement_combat.gd::test_jump_goes_up_and_lands | |
| Movement | Strafing and mouse steering | client/test_player_controller.gd::test_forward_back_and_strafe_keys; client/test_player_controller.gd::test_right_drag_steers_character_and_camera | |
| Movement | Only the strongest slow applies | core/test_combat.gd::test_only_the_strongest_slow_applies | |
| Movement | Pillars and the arena bounds block movement | core/test_movement_combat.gd::test_pillar_blocks_movement; core/test_movement_combat.gd::test_bounds_keep_unit_inside | |
| Stats | Every spec uses a fixed stat template; health starts at 60,000 for DPS and healers, 72,000 for tanks | core/test_combat.gd::test_spec_health_comes_from_the_role_template; test_combat_rule_data.py::test_health_comes_from_the_role_template | |
| Damage | Physical damage is reduced by armor: cloth 10%, leather 20%, mail 25%, plate 30% | core/test_combat.gd::test_physical_damage_by_armor_type | |
| Damage | Magic ignores armor; critical strikes multiply by 1.5 | core/test_combat.gd::test_magic_ignores_armor_and_crits_multiply_by_1_5 | |
| Damage | The power bonus, target damage-taken modifiers and each ability's PvP modifier scale damage | core/test_combat.gd::test_power_bonus_damage_taken_and_pvp_modifier_scale_damage | |
| Resources | Abilities need their resource; mana regenerates | core/test_combat.gd::test_cannot_cast_without_resource_and_mana_regenerates | |
| Resources | Rage builds from dealing and taking damage and decays out of combat | core/test_combat.gd::test_rage_builds_from_damage_and_decays_out_of_combat; core/test_kits.gd::test_auto_attacks_and_damage_taken_build_rage | |
| Auras | Periodic effects tick and expire; stacking buffs cap | core/test_combat.gd::test_periodic_damage_and_expiry; core/test_combat.gd::test_stacking_buff_caps_at_max_stacks | |
| Crowd control | Repeated crowd control in one category lasts 100%, 50%, 25%, then immune | core/test_combat.gd::test_stun_diminishing_returns_100_50_25_then_immune; core/test_crowd_control.gd::test_every_category_steps_100_50_25_then_immune | |
| Crowd control | Diminishing returns reset 18 s after the last effect in the category ends | core/test_combat.gd::test_dr_resets_18_s_after_the_last_cc_ends; core/test_crowd_control.gd::test_diminishing_returns_reset_18_s_after_the_last_effect_ends_in_each_category | |
| Crowd control | No crowd control lasts longer than 8 s | core/test_combat.gd::test_no_cc_lasts_longer_than_8_s; core/test_crowd_control.gd::test_no_category_lasts_longer_than_8_s | |
| Crowd control | Incapacitate breaks on any damage | core/test_combat.gd::test_incapacitate_breaks_on_damage; core/test_crowd_control.gd::test_incapacitate_blocks_everything_and_breaks_on_any_damage | |
| Crowd control | Disorient breaks after damage over 10% of max health | core/test_crowd_control.gd::test_disorient_takes_control_and_breaks_past_10_percent_of_max_health; test_combat_rule_data.py::test_crowd_control_auras_follow_their_category_break_rule | |
| Crowd control | Silence and stun do not break on damage; some roots break after a damage threshold | core/test_crowd_control.gd::test_stun_blocks_everything_and_holds_through_damage; core/test_crowd_control.gd::test_silence_blocks_spells_but_not_weapon_attacks_and_holds_through_damage; core/test_crowd_control.gd::test_root_stops_movement_but_not_casting_and_breaks_by_its_data; test_combat_rule_data.py::test_crowd_control_auras_follow_their_category_break_rule | |
| Crowd control | Disarm (own category) and knockback (no diminishing returns) | core/test_crowd_control.gd::test_disarm_blocks_weapon_attacks_and_auto_attack_but_not_spells; core/test_crowd_control.gd::test_knockback_pushes_every_time_with_no_diminishing_returns; core/test_crowd_control.gd::test_categories_keep_separate_diminishing_returns | |
| Crowd control | Stun blocks abilities; Break Free removes all crowd control | core/test_combat.gd::test_stun_blocks_abilities_but_break_free_removes_it; core/test_crowd_control.gd::test_break_free_works_under_every_category | |
| Crowd control | Break Free has a 90 s cooldown | core/test_combat.gd::test_break_free_waits_90_s_between_uses; test_combat_rule_data.py::test_break_free_has_a_90_s_cooldown | |
| Dispels | Dispels remove effects by type | core/test_combat.gd::test_dispel_removes_a_magic_debuff_from_an_ally; core/test_kits.gd::test_absolve_removes_a_magic_slow_from_an_ally | |
| Dispels | An offensive dispel strips one magic buff | core/test_combat.gd::test_offensive_dispel_strips_one_magic_buff | |
| Targeting | Tab picks the nearest enemy in front | core/test_movement_combat.gd::test_tab_picks_nearest_enemy_in_front | |
| Targeting | Focus, mouseover, self, arena 1 to 3 and party targets per keybind | client/test_keybind_screen.gd::test_the_controller_aims_each_mode_at_its_unit; client/test_keybind_screen.gd::test_a_focus_cast_hits_the_focus_and_keeps_the_target | |
| Line of sight | A pillar blocks line of sight | core/test_movement_combat.gd::test_line_of_sight_blocked_by_pillar | |
| Line of sight | Line of sight is checked when a cast starts and when it finishes | core/test_combat.gd::test_cast_fails_if_target_steps_behind_a_pillar_before_it_finishes | |
| Ranges | Melee 5 m (auto attack only in range), most ranged abilities and healing 40 m | core/test_movement_combat.gd::test_auto_attack_swings_every_2_seconds_in_range_only; test_combat_rule_data.py::test_healing_reaches_40_m_and_most_ranged_abilities_do | |
| Arena | Preparation behind closed gates, then the gates open | core/test_arena_match.gd::test_gates_hold_players_in_during_preparation_then_open | |
| Arena | Dampening from 3:00, 1% every 10 s; in 1v1 from 1:00; it reduces healing | core/test_arena_match.gd::test_dampening_starts_at_3_minutes_and_drops_1_percent_per_10_s; core/test_arena_match.gd::test_one_v_one_dampening_starts_at_1_minute; core/test_kits.gd::test_healing_is_reduced_by_dampening | |
| Arena | A match ends when a team is fully dead | core/test_arena_match.gd::test_team_elimination_wins | |
| Arena | A 2v2 or 3v3 match is a draw at 20:00; a 1v1 at 12:00 | core/test_arena_match.gd::test_draw_at_20_minutes; core/test_arena_match.gd::test_one_v_one_is_a_draw_at_12_minutes | |
| Arena | Health and mana pickups light up once at 1:30 in 1v1 and 2v2; the first living player in reach takes one | core/test_arena_match.gd::test_pickups_light_up_once_at_1_30_in_1v1_and_2v2_only; core/test_arena_match.gd::test_the_first_player_in_reach_takes_a_pickup_and_it_does_not_return; core/test_arena_match.gd::test_a_pickup_restores_health_and_mana_over_time_through_the_runner | |
| Simulation | The simulation runs at a fixed tick rate independent of frame rate, and the same seed and inputs give the same state | core/test_sim.gd::test_600_ticks_is_10_seconds; core/test_sim.gd::test_advance_is_independent_of_frame_rate; core/test_sim.gd::test_same_seed_and_inputs_give_same_hash; core/test_replay.gd::test_bot_arena_match_replays_to_the_same_hash | |
