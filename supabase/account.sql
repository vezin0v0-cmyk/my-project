-- Удаление своего аккаунта Nova из кабинета (Профиль → Удалить аккаунт).
-- Как применить: Supabase → SQL Editor → вставить целиком → Run. Повторный запуск ничего не ломает.
--
-- Кто может вызвать: только вошедший пользователь, и только для себя (id берётся из его токена).
-- Гость с публичным ключом сайта вызвать функцию не может.
-- Защита от украденной сессии: удалить можно только в первые 10 минут после ввода пароля или кода
-- из письма. Сайт перед удалением просит пароль ещё раз, поэтому у владельца это всегда так.
-- Фото профиля сайт удаляет сам до вызова: Supabase не разрешает удалять файлы хранилища из SQL.

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  fresh boolean;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  -- amr — когда и как человек последний раз подтвердил, что это он (пароль, код из письма).
  -- Обновление токена это время не меняет, поэтому старую сессию «освежить» не получится.
  select coalesce(bool_or((e ->> 'timestamp')::bigint > extract(epoch from now())::bigint - 600), false)
    into fresh
    from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) as e;
  if not fresh then
    raise exception 'reauthentication required' using errcode = '28000';
  end if;

  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
