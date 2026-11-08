-- Plate game schema. All writes happen via SECURITY DEFINER RPCs; clients only SELECT.
create table profiles(
  id uuid primary key references auth.users on delete cascade,
  username text unique not null check (char_length(username) between 3 and 20),
  balance bigint not null default 1000 check (balance >= 0),
  xp int not null default 0, level int not null default 1,
  streak int not null default 0, last_claim date,
  plates_found int not null default 0, plates_sold int not null default 0,
  created_at timestamptz not null default now());

-- Global registry: PRIMARY KEY on plate text = DB-enforced single ownership of each exact plate.
create table plates(
  plate text primary key, serial bigint generated always as identity,
  region text not null, rarity text not null, score int not null, base_value bigint not null,
  owner_id uuid not null references profiles, listed boolean not null default false,
  found_at timestamptz not null default now());
create index on plates(owner_id);

create table listings(
  id bigint generated always as identity primary key,
  plate text not null references plates, seller_id uuid not null references profiles,
  buyer_id uuid references profiles, price bigint not null check (price > 0),
  status text not null default 'active' check (status in ('active','sold','cancelled')),
  created_at timestamptz not null default now());
-- A plate can have at most one active listing => cannot be sold twice.
create unique index one_active_listing on listings(plate) where status='active';

create table transactions(
  id bigint generated always as identity primary key,
  user_id uuid references profiles, kind text not null, plate text,
  amount bigint not null, created_at timestamptz not null default now());

alter table profiles enable row level security;
alter table plates enable row level security;
alter table listings enable row level security;
alter table transactions enable row level security;
create policy read_all on profiles for select using (true);
create policy read_all on plates for select using (true);
create policy read_all on listings for select using (true);
create policy read_all on transactions for select using (true);
-- No insert/update/delete policies: direct client writes are impossible.

create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into profiles(id,username) values(new.id, coalesce(new.raw_user_meta_data->>'username','player'||substr(new.id::text,1,6))); return new; end $$;
create trigger on_signup after insert on auth.users for each row execute function handle_new_user();

-- Rarity from PATTERN (score), so rarity is naturally scarce with uniform rolls.
create function plate_score(l text, d text, r text) returns int language plpgsql immutable as $$
declare s int := 0; n int := d::int;
begin
  if substr(d,1,1)=substr(d,2,1) and substr(d,2,1)=substr(d,3,1) then s:=s+4; end if;   -- 111
  if d like '00%' then s:=s+5; end if;                                                    -- 001
  if d in ('123','234','345','456','567','678','789') then s:=s+2; end if;                -- sequential
  if substr(d,1,1)=substr(d,3,1) then s:=s+1; end if;                                     -- palindrome
  if d='777' then s:=s+2; end if;
  if substr(l,1,1)=substr(l,3,1) then s:=s+1; end if;                                     -- A..A
  if substr(l,1,1)=substr(l,2,1) and substr(l,2,1)=substr(l,3,1) then s:=s+3; end if;     -- AAA
  if r in ('77','99','97','177','197','199','777','78','178','98') then s:=s+1; end if;   -- capital regions
  if char_length(r)=3 then s:=s+1; end if;
  if r='77' and d='777' then s:=s+2; end if;
  return s; end $$;

create function rarity_of(s int) returns text language sql immutable as $$
 select case when s>=11 then 'Exclusive' when s>=9 then 'Ultra Rare' when s>=7 then 'Mythical'
 when s>=5 then 'Legendary' when s=4 then 'Epic' when s>=2 then 'Rare' when s=1 then 'Uncommon' else 'Common' end $$;

create function add_xp(uid uuid, x int) returns void language sql as $$
 update profiles set xp=xp+x, level=1+floor(sqrt((xp+x)/50.0))::int where id=uid $$;

create function generate_plate() returns plates language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); cost int:=100; pr profiles; p plates; n int:=0;
 al text[]:=array['A','B','E','K','M','H','O','P','C','T','Y','X'];
 rg text[]:=array['77','99','97','177','197','199','777','78','178','98','50','150','750','52','152','16','116','716','02','102','59','159','63','163','86','186','72','74','174','66','196','96','24','124','38','138','54','154','42','142','61','161','93','123','193','23','34','134','36','136','47','178','13','113','21','121','10','11','12','14','15','17','18','19','25','26','27','28','29','30','31','32','33','35','37','39','40','41','43','44','45','46','48','49','51','53','55','56','57','58','60','62','64','164','67','68','69','70','71','73','174','75','76','79','82','83','84','85','87','89'];
 l text; d text; r text; s int;
begin
 if uid is null then raise exception 'not authenticated'; end if;
 select * into pr from profiles where id=uid for update;
 if pr.balance<cost then raise exception 'insufficient funds'; end if;
 loop
  n:=n+1; if n>40 then raise exception 'no free plate found, try again'; end if;
  l:=al[1+floor(random()*12)]||al[1+floor(random()*12)]||al[1+floor(random()*12)];
  if random()<0.12 then l:=substr(l,1,1)||substr(l,2,1)||substr(l,1,1); end if;
  d:=lpad(floor(random()*1000)::text,3,'0');
  r:=rg[1+floor(random()*array_length(rg,1))];
  s:=plate_score(l,d,r);
  insert into plates(plate,region,rarity,score,base_value,owner_id)
   values(substr(l,1,1)||d||substr(l,2,2)||r, r, rarity_of(s), s, round(60*power(2.1,s)), uid)
   on conflict (plate) do nothing returning * into p;   -- race-safe: loser retries with new plate
  exit when p.plate is not null;
 end loop;
 update profiles set balance=balance-cost, plates_found=plates_found+1 where id=uid;
 insert into transactions(user_id,kind,plate,amount) values(uid,'generate',p.plate,-cost);
 perform add_xp(uid,10+s*10);
 return p; end $$;

create function claim_daily() returns bigint language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); pr profiles; st int; rew bigint;
begin
 select * into pr from profiles where id=uid for update;
 if pr.last_claim=current_date then raise exception 'already claimed today'; end if;
 st:=case when pr.last_claim=current_date-1 then pr.streak+1 else 1 end;
 rew:=150+30*least(st,7)+case when st%7=0 then 500 else 0 end;
 update profiles set balance=balance+rew, streak=st, last_claim=current_date where id=uid;
 insert into transactions(user_id,kind,amount) values(uid,'daily',rew);
 perform add_xp(uid,20); return rew; end $$;

create function list_plate(p_plate text, p_price bigint) returns bigint language plpgsql security definer set search_path=public as $$
declare id bigint; uid uuid:=auth.uid();
begin
 update plates set listed=true where plate=p_plate and owner_id=uid and not listed;
 if not found then raise exception 'not your plate or already listed'; end if;
 insert into listings(plate,seller_id,price) values(p_plate,uid,p_price) returning listings.id into id; return id; end $$;

create function cancel_listing(p_id bigint) returns void language plpgsql security definer set search_path=public as $$
declare l listings;
begin
 update listings set status='cancelled' where id=p_id and seller_id=auth.uid() and status='active' returning * into l;
 if not found then raise exception 'listing not cancellable'; end if;
 update plates set listed=false where plate=l.plate; end $$;

create function buy_listing(p_id bigint) returns void language plpgsql security definer set search_path=public as $$
declare l listings; uid uuid:=auth.uid(); fee bigint;
begin
 select * into l from listings where id=p_id and status='active' for update;
 if not found then raise exception 'listing no longer available'; end if;
 if l.seller_id=uid then raise exception 'cannot buy your own plate'; end if;
 perform 1 from profiles where id in (uid,l.seller_id) order by id for update;   -- fixed lock order, no deadlocks
 fee:=l.price*5/100;                                                              -- 5% fee destroyed: anti-inflation sink
 update profiles set balance=balance-l.price where id=uid;                        -- CHECK >=0 rejects overspend
 update profiles set balance=balance+l.price-fee, plates_sold=plates_sold+1 where id=l.seller_id;
 update plates set owner_id=uid, listed=false where plate=l.plate;
 update listings set status='sold', buyer_id=uid where id=p_id;
 insert into transactions(user_id,kind,plate,amount) values(uid,'purchase',l.plate,-l.price),(l.seller_id,'sale',l.plate,l.price-fee);
 perform add_xp(uid,15); perform add_xp(l.seller_id,25); end $$;

revoke execute on function add_xp, plate_score from public, anon, authenticated;
alter publication supabase_realtime add table listings, plates;

create view leaderboard as
 select p.id, p.username, p.balance, p.level, p.plates_sold,
  coalesce((select sum(base_value) from plates where owner_id=p.id),0) as collection_value,
  (select count(*) from plates where owner_id=p.id) as plate_count from profiles p;
grant select on leaderboard to anon, authenticated;
