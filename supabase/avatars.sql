-- Применено к проекту Supabase «nova». Запускать в SQL Editor, если проект создаётся заново.
-- Хранилище фото профиля: читать может кто угодно (по ссылке), а загружать, менять и удалять —
-- только владелец и только один файл: <id пользователя>/avatar.jpg. Так хранилище нельзя забить
-- чужими файлами: у каждого ровно одна картинка до 2 МБ.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "avatars: read own" on storage.objects;
drop policy if exists "avatars: upload own" on storage.objects;
drop policy if exists "avatars: update own" on storage.objects;
drop policy if exists "avatars: delete own" on storage.objects;

create policy "avatars: read own" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg');
create policy "avatars: upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg');
create policy "avatars: update own" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg')
  with check (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg');
create policy "avatars: delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg');
