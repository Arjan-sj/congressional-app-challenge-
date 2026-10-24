-- SELECT only, usable before the Phase 1 migration. Run in a trusted operator
-- connection and record the requested project identity alongside its result.
-- Every existing row is protected until separately registered as synthetic;
-- is_demo alone never authorizes deleting a report or its evidence/audit.
select jsonb_build_object(
  'counts',jsonb_build_object(
    'hazard_reports',(select count(*) from public.hazard_reports),
    'demo_reports',(select count(*) from public.hazard_reports where is_demo),
    'photo_metadata',(select count(*) from public.hazard_report_photos),
    'storage_objects',(select count(*) from storage.objects where bucket_id='hazard-photos'),
    'report_flags',(select count(*) from public.report_flags),
    'moderation_history',(select count(*) from public.report_moderation_history),
    'correction_records',(select count(*) from private.report_school_corrections)),
  'unsafe_report_ids',(select coalesce(jsonb_agg(id order by id),'[]') from public.hazard_reports),
  'orphan_storage_objects',(select coalesce(jsonb_agg(o.name order by o.name),'[]') from storage.objects o
    where bucket_id='hazard-photos' and not exists(select from public.hazard_report_photos p where p.storage_path=o.name)),
  'orphan_corrections',(select coalesce(jsonb_agg(c.report_id order by c.report_id),'[]')
    from private.report_school_corrections c where not exists(select from public.hazard_reports h where h.id=c.report_id)),
  'buckets',(select jsonb_agg(jsonb_build_object('id',id,'public',public,'file_size_limit',file_size_limit,
    'allowed_mime_types',allowed_mime_types)) from storage.buckets where id='hazard-photos'),
  'foreign_keys',(select jsonb_agg(jsonb_build_object('table',conrelid::regclass::text,'name',conname,
    'definition',pg_get_constraintdef(oid))) from pg_constraint where contype='f' and confrelid in (
      'public.hazard_reports'::regclass,'public.hazard_report_photos'::regclass,
      'public.report_flags'::regclass,'public.report_moderation_history'::regclass)),
  'triggers',(select jsonb_agg(jsonb_build_object('table',tgrelid::regclass::text,'name',tgname,
    'definition',pg_get_triggerdef(oid))) from pg_trigger where not tgisinternal and tgrelid in (
      'public.hazard_reports'::regclass,'public.hazard_report_photos'::regclass)),
  'migrations',(select jsonb_agg(jsonb_build_object('version',version,'name',name) order by version)
    from supabase_migrations.schema_migrations)
) as audit;
