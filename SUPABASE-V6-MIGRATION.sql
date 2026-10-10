-- LUXE POINT V6 MIGRATION — SAFE / NON-DESTRUCTIVE
-- Jalankan setelah SUPABASE-V4.sql dan SUPABASE-V5-INSTANT-USERNAME.sql pada project Supabase yang sama.
-- Tidak menghapus tabel, order, admin, promo, produk, atau ulasan.
begin;

alter table public.promos add column if not exists min_purchase bigint not null default 0;
alter table public.promos add column if not exists max_uses integer;
alter table public.promos add column if not exists allowed_method text not null default 'all';
alter table public.promos drop constraint if exists promos_max_uses_positive;
alter table public.promos add constraint promos_max_uses_positive check (max_uses is null or max_uses > 0);
alter table public.promos drop constraint if exists promos_min_purchase_nonnegative;
alter table public.promos add constraint promos_min_purchase_nonnegative check (min_purchase >= 0);
alter table public.promos drop constraint if exists promos_allowed_method_valid;
alter table public.promos add constraint promos_allowed_method_valid check (allowed_method in ('all','gamepass','instant_username'));

create or replace function public.get_valid_promo_discount(p_code text,p_purchase bigint,p_method text)
returns numeric language plpgsql security definer set search_path=public as $$
declare result numeric; used_count bigint;
begin
  if coalesce(trim(p_code),'')='' then return 0; end if;
  select count(*) into used_count from public.orders o
    where upper(coalesce(o.promo_code,''))=upper(trim(p_code)) and o.status <> 'cancelled';
  select p.discount_percent into result from public.promos p
    where upper(p.code)=upper(trim(p_code)) and p.active=true
      and now() between p.starts_at and p.expires_at
      and coalesce(p_purchase,0)>=coalesce(p.min_purchase,0)
      and (p.allowed_method='all' or p.allowed_method=p_method)
      and (p.max_uses is null or used_count<p.max_uses)
    limit 1;
  return result;
end; $$;
revoke all on function public.get_valid_promo_discount(text,bigint,text) from public;
grant execute on function public.get_valid_promo_discount(text,bigint,text) to anon, authenticated;

create or replace function public.create_public_order(p_product_id bigint,p_roblox_username text,p_promo_code text default null)
returns table(order_code text, robux_amount integer, price bigint, promo_code text)
language plpgsql security definer set search_path=public
as $$
declare
  p public.products%rowtype;
  st integer;
  final_price bigint;
  original_price bigint;
  discount_amount bigint;
  promo_discount numeric := 0;
  normalized_code text;
  new_code text;
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  i integer;
begin
  if length(trim(p_roblox_username)) < 2 or length(trim(p_roblox_username)) > 30 then
    raise exception 'Username Roblox tidak valid.';
  end if;
  select * into p from public.products where id=p_product_id and active=true limit 1;
  if not found then raise exception 'Paket Robux tidak tersedia.'; end if;
  select stock into st from public.store_settings where id=1;
  if coalesce(st,0) < p.robux then raise exception 'Stok Robux tidak cukup.'; end if;
  normalized_code=upper(trim(coalesce(p_promo_code,'')));
  if normalized_code <> '' then
    promo_discount := public.get_valid_promo_discount(normalized_code, p.price, 'gamepass');
    if promo_discount is null then raise exception 'Kode promo tidak valid atau sudah kedaluwarsa.'; end if;
  else
    normalized_code=null;
  end if;
  original_price=p.price;
  final_price=round(p.price*(1-(promo_discount/100)))::bigint;
  discount_amount=greatest(0,original_price-final_price);
  loop
    new_code='LP-'||to_char(now(),'YYYYMMDD')||'-';
    for i in 1..5 loop new_code=new_code||substr(chars,1+floor(random()*length(chars))::int,1); end loop;
    begin
      insert into public.orders(order_code,roblox_username,robux_amount,price,promo_code,product_name,original_price,discount_amount,status,order_type)
      values(new_code,trim(p_roblox_username),p.robux,final_price,normalized_code,
             initcap(p.method)||' '||p.robux||' Robux',original_price,discount_amount,'pending','gamepass');
      exit;
    exception when unique_violation then
    end;
  end loop;
  return query select new_code,p.robux,final_price,normalized_code;
end; $$;

create or replace function public.create_instant_order(
  p_robux_amount integer,
  p_roblox_username text,
  p_customer_whatsapp text,
  p_promo_code text default null
)
returns table(
  order_code text,
  robux_amount integer,
  subtotal bigint,
  discount_amount bigint,
  tax_amount bigint,
  admin_fee bigint,
  price bigint,
  promo_code text
)
language plpgsql
security definer
set search_path=public
as $$
declare
  st integer;
  rate bigint;
  tax_rate numeric;
  fee bigint;
  base_price bigint;
  discount bigint := 0;
  taxable bigint;
  tax bigint;
  total bigint;
  promo_discount numeric := 0;
  normalized_code text;
  normalized_wa text;
  new_code text;
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  i integer;
  promo_exists boolean := false;
begin
  -- Validasi jumlah custom.
  if p_robux_amount is null or p_robux_amount < 10 or mod(p_robux_amount,10) <> 0 then
    raise exception 'Jumlah Robux minimal 10 dan harus kelipatan 10.';
  end if;

  if length(trim(coalesce(p_roblox_username,''))) < 2 or length(trim(p_roblox_username)) > 30 then
    raise exception 'Username Roblox tidak valid.';
  end if;

  -- Nomor WhatsApp customer bersifat opsional. Jika diisi, simpan hanya angka/+.
  normalized_wa := nullif(regexp_replace(coalesce(p_customer_whatsapp,''),'[^0-9+]','','g'),'');

  select ss.stock, ss.rate_per_10, ss.tax_percent, ss.admin_fee
  into st, rate, tax_rate, fee
  from public.store_settings as ss
  where ss.id=1;

  if coalesce(st,0) < p_robux_amount then
    raise exception 'Stok Robux tidak mencukupi.';
  end if;

  if coalesce(rate,0) <= 0 then
    raise exception 'Tarif Robux belum diatur admin.';
  end if;

  -- Harga dasar: Rp1.500 per 10 Robux secara default.
  base_price := (p_robux_amount / 10) * rate;

  normalized_code := upper(trim(coalesce(p_promo_code,'')));

  if normalized_code <> '' then
    promo_discount := public.get_valid_promo_discount(normalized_code, base_price, 'instant_username');

    if promo_discount is null then
      raise exception 'Kode promo tidak valid atau sudah kedaluwarsa.';
    end if;

    promo_exists := true;
  else
    normalized_code := null;
  end if;

  discount := round(base_price * (coalesce(promo_discount,0) / 100))::bigint;
  taxable := greatest(0,base_price-discount);
  tax := round(taxable * (coalesce(tax_rate,11) / 100))::bigint;
  total := taxable + tax + coalesce(fee,100);

  loop
    new_code := 'LP-' || to_char(now(),'YYYYMMDD') || '-';
    for i in 1..5 loop
      new_code := new_code || substr(chars,1+floor(random()*length(chars))::integer,1);
    end loop;

    begin
      insert into public.orders(
        order_code,
        roblox_username,
        robux_amount,
        price,
        promo_code,
        product_name,
        original_price,
        discount_amount,
        order_type,
        customer_whatsapp,
        subtotal,
        tax_amount,
        admin_fee,
        status
      ) values (
        new_code,
        trim(p_roblox_username),
        p_robux_amount,
        total,
        normalized_code,
        'Robux Instant via Username',
        base_price,
        discount,
        'instant_username',
        normalized_wa,
        base_price,
        tax,
        coalesce(fee,100),
        'pending'
      );
      exit;
    exception when unique_violation then
      null;
    end;
  end loop;

  -- Catatan: admin_fee disimpan sesuai tarif admin.
  -- Nilai admin_fee dan tax_amount sudah disimpan saat INSERT.
  -- Tidak perlu UPDATE tambahan yang dapat bentrok dengan OUT parameter.

  return query
  select new_code,p_robux_amount,base_price,discount,tax,coalesce(fee,100),total,normalized_code;
end;
$$;

commit;

-- Catatan: dashboard menghitung pemakaian dari order yang bukan cancelled.
-- Validasi utama promo dilakukan di RPC server-side, bukan hanya di browser.
