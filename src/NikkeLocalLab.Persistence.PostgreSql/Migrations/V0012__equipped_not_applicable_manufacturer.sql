ALTER TABLE lab_profile.build_equipment_state
    DROP CONSTRAINT build_equipment_state_check;

ALTER TABLE lab_profile.build_equipment_state
    ADD CONSTRAINT build_equipment_state_check CHECK (
        (equipment_state = 'equipped'
            AND definition_entity_id IS NOT NULL
            AND definition_version_id IS NOT NULL
            AND definition_kind IS NOT NULL
            AND definition_kind = 'equipment'
            AND enhancement_level_status IS NOT NULL
            AND lab_profile.valid_fact(
                enhancement_level_status,
                enhancement_level IS NOT NULL,
                enhancement_level_unresolved_reason_code
            )
            AND manufacturer_matched_status IS NOT NULL
            AND equipment_unresolved_reason_code IS NULL)
        OR (equipment_state = 'unequipped'
            AND definition_entity_id IS NULL
            AND definition_version_id IS NULL
            AND definition_kind IS NULL
            AND enhancement_level_status IS NULL
            AND enhancement_level IS NULL
            AND enhancement_level_unresolved_reason_code IS NULL
            AND manufacturer_matched_status IS NOT NULL
            AND manufacturer_matched_status = 'not_applicable'
            AND equipment_unresolved_reason_code IS NULL
            AND overload_line_count = 0)
        OR (equipment_state = 'unresolved'
            AND definition_entity_id IS NULL
            AND definition_version_id IS NULL
            AND definition_kind IS NULL
            AND enhancement_level_status IS NULL
            AND enhancement_level IS NULL
            AND enhancement_level_unresolved_reason_code IS NULL
            AND manufacturer_matched_status IS NULL
            AND manufacturer_matched IS NULL
            AND manufacturer_matched_unresolved_reason_code IS NULL
            AND equipment_unresolved_reason_code IS NOT NULL
            AND overload_line_count = 0)
    );
