-- ════════════════════════════════════════════════════════════
-- Q-TRACKER HAFAZAN — SETUP KESELAMATAN SUPABASE
-- Jalankan skrip ini dalam Supabase Dashboard → SQL Editor
-- ════════════════════════════════════════════════════════════
--
-- KENAPA SKRIP INI PERLU:
-- Versi asal app membenarkan sesiapa sahaja (termasuk murid yang buka
-- URL app di telefon sendiri) menulis terus ke jadual hafazan_records
-- melalui anon key. Skrip ini menutup lubang itu dengan:
--   1. RLS (Row Level Security) — anon (tanpa log masuk) hanya boleh
--      SELECT (baca), langsung TIDAK boleh INSERT/UPDATE/DELETE.
--   2. Semua operasi TULIS mesti melalui fungsi RPC di bawah, yang
--      check auth.uid() (mesti log masuk sebagai guru) dan
--      menguatkuasakan sekatan lonjakan blok ayat DI SERVER —
--      bukan sekadar di JavaScript client yang boleh dipintas.
--
-- NOTA: anon key yang kelihatan dalam kod HTML adalah NORMAL untuk
-- app Supabase — ia BUKAN rahsia yang perlu disembunyikan. Keselamatan
-- sebenar datang daripada RLS + Auth di bawah, bukan daripada
-- menyembunyikan key tersebut.

-- ── 1. Tambah lajur untuk jejak audit (siapa hantar rekod terakhir) ──
alter table hafazan_records add column if not exists last_guru text;

-- ── 2. Aktifkan RLS ──
alter table hafazan_records enable row level security;

-- Buang mana-mana policy lama yang mungkin terlalu longgar
drop policy if exists "public insert" on hafazan_records;
drop policy if exists "public update" on hafazan_records;
drop policy if exists "public select" on hafazan_records;
drop policy if exists "Enable read access for all users" on hafazan_records;
drop policy if exists "Enable insert for all users" on hafazan_records;
drop policy if exists "Enable update for all users" on hafazan_records;

-- Hanya guru yang log masuk (authenticated) boleh BACA
create policy "guru boleh baca"
on hafazan_records
for select
to authenticated
using (true);

-- TIADA policy insert/update/delete langsung diberi — semua tulisan
-- mesti melalui fungsi RPC security-definer di bawah.
revoke insert, update, delete on hafazan_records from anon, authenticated;
revoke select on hafazan_records from anon;
grant select on hafazan_records to authenticated;

-- ── 3. RPC: hantar rekod bacaan (guna dalam hantarRekod()) ──
-- Menguatkuasakan: mesti log masuk, UID kad mesti sepadan, dan murid
-- tidak boleh dilonjak lebih 1 blok ke hadapan daripada progress semasa.
create or replace function submit_hafazan_record(
  p_murid_id bigint,
  p_last_ayat text,
  p_nfc_id text,
  p_status text,
  p_block int,
  p_total_blocks int,
  p_tingkatan text,
  p_surah text
) returns setof hafazan_records
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row hafazan_records;
  v_current_block int;
  v_new_block int;
  v_new_peratus int;
begin
  if auth.uid() is null then
    raise exception 'Sila log masuk sebagai guru.';
  end if;

  select * into v_row from hafazan_records where id = p_murid_id for update;
  if not found then
    raise exception 'Murid tidak dijumpai.';
  end if;

  if v_row.nfc_id is not null and v_row.nfc_id <> p_nfc_id then
    raise exception 'UID kad tidak sepadan dengan murid ini.';
  end if;

  v_current_block := coalesce(v_row.lulus_block, 0);

  -- Sekat lonjakan: hanya boleh maju 1 blok pada satu masa
  if p_block > v_current_block + 1 then
    raise exception 'Tidak boleh langkau ayat — murid perlu ikut turutan.';
  end if;

  if p_status = 'lancar' then
    v_new_block := greatest(v_current_block, p_block);
  else
    v_new_block := greatest(v_current_block, p_block - 1);
  end if;

  v_new_peratus := round((v_new_block::numeric / greatest(p_total_blocks, 1)) * 100);

  update hafazan_records
  set last_ayat   = p_last_ayat,
      nfc_id       = p_nfc_id,
      peratus      = v_new_peratus,
      bintang      = v_new_block,
      lulus_block  = v_new_block,
      tingkatan    = p_tingkatan,
      surah        = p_surah,
      last_guru    = auth.email()
  where id = p_murid_id;

  return query select * from hafazan_records where id = p_murid_id;
end;
$$;

revoke execute on function submit_hafazan_record from public;
grant execute on function submit_hafazan_record(bigint, text, text, text, int, int, text, text) to authenticated;

-- ── 4. RPC: daftar murid baharu (guna dalam saveRegister()) ──
create or replace function register_student(
  p_nama text,
  p_tingkatan text,
  p_surah text,
  p_kelas text,
  p_nfc_id text
) returns setof hafazan_records
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_id bigint;
begin
  if auth.uid() is null then
    raise exception 'Sila log masuk sebagai guru.';
  end if;

  if exists (select 1 from hafazan_records where nfc_id = p_nfc_id) then
    raise exception 'Kad ini sudah didaftarkan kepada murid lain.';
  end if;

  insert into hafazan_records (nama_murid, tingkatan, surah, kelas, nfc_id, lulus_block, bintang, peratus, last_guru)
  values (p_nama, p_tingkatan, p_surah, p_kelas, p_nfc_id, 0, 0, 0, auth.email())
  returning id into v_new_id;

  return query select * from hafazan_records where id = v_new_id;
end;
$$;

revoke execute on function register_student from public;
grant execute on function register_student(text, text, text, text, text) to authenticated;

-- ── 5. RPC: kaitkan kad sedia ada ke murid (guna dalam saveLinkCard()) ──
create or replace function link_student_card(
  p_murid_id bigint,
  p_nfc_id text
) returns setof hafazan_records
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Sila log masuk sebagai guru.';
  end if;

  if exists (select 1 from hafazan_records where nfc_id = p_nfc_id and id <> p_murid_id) then
    raise exception 'Kad ini sudah dikaitkan dengan murid lain.';
  end if;

  update hafazan_records set nfc_id = p_nfc_id where id = p_murid_id;

  if not found then
    raise exception 'Murid tidak dijumpai.';
  end if;

  return query select * from hafazan_records where id = p_murid_id;
end;
$$;

revoke execute on function link_student_card from public;
grant execute on function link_student_card(bigint, text) to authenticated;

-- ════════════════════════════════════════════════════════════
-- LANGKAH SETERUSNYA (buat dalam Supabase Dashboard, bukan SQL):
--
-- 1. Authentication → Providers → pastikan "Email" enabled.
-- 2. Authentication → Settings → MATIKAN "Allow new users to sign up"
--    (supaya bukan sesiapa boleh daftar akaun sendiri).
-- 3. Authentication → Users → "Add user" untuk setiap guru secara
--    manual (emel + kata laluan). Ini akaun yang guru guna log masuk
--    dalam app.
-- ════════════════════════════════════════════════════════════
