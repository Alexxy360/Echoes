# Rzeczywisty protokół metadanych Development — CK-05a.4h

19 listopada 2026. **Próba zaliczona:9wywołań batch,8własnych rekordów zapisanych, zweryfikowanych i potwierdzonych jako nieobecne po sprzątaniu.** To odbiór protokołu metadanych w CloudKit Development, z kontem właściciela jako administratorem. Gateway pozostaje nieaktywny. [Dowody](evidence/community-protocol-development-verification.json), [zatwierdzony zakres](ZAKRES_PROBY_COMMUNITY_DEVELOPMENT.md).

## Zgoda i konfiguracja

Właściciel osobno odpowiedział „Tak, zatwierdzam cały opisany zakres” na przygotowane pytanie obejmujące wycofanie starego klucza, nowy lokalny klucz Development, przypisanie istniejącej roli wyłącznie właścicielowi i jeden test ośmiu syntetycznych rekordów. Zakres był zapisany w commicie5432db8. Wcześniejsza zgoda na sam model Individual nie została użyta jako zgoda na te operacje.

W CloudKit Console potwierdzono `iCloud.mpvEcho.Echo`, zespół22YC9RAP4P, Development i jedną starą rejestrację S2S. Jej pełny ID zgadzał się z lokalnymi metadanymi. Po trwałym Delete panel pokazał **No Server-to-Server Keys**. Dopiero potem wygenerowano nowy P-256 i zarejestrowano jego publiczną część jako **Echoes Community Development 2026-11-19**, ID `e601721628f60c732d866bf669dcea4c2dfc7e99cb7dc9f68643a5a778330b10`, publiczny SPKI SHA256 `dff346013b6931700abe67b7b2358fcd2f36c8c9dd22481dbadbae9f5b9aee60`.

Prywatny klucz i metadane są lokalnie w osobnym katalogu0700/pliki0600 pod Application Support/Echoes, poza repozytorium. Nie przekazano go Cloudflare lub aplikacji iOS. Kontrolę commitów rozszerzono o wykrywanie obu znanych kluczy prywatnych. Stara lokalna kopia nie została użyta do ponownej próby; odwołanie jej rejestracji potwierdzono w konsoli, bez nowego żądania podpisanego starym kluczem.

Przez **Fetch Records jednego znanego ID**, bez listowania innych kont, odczytano istniejący rekord Users właściciela. Początkowo miał tylko EchoesGatewayProbeService; EchoesCommunityService była niezaznaczona. Dodano wyłącznie zatwierdzoną rolę. Apple pokazało „Role “EchoesCommunityService” has been added to the user.”, a oba checkboxy pozostały zaznaczone. Nie edytowano pól Users, schematu, innych kont lub Production. Konto właściciela ma odtąd administracyjny dostęp również z SDK poza polityką3km — zgodnie z przyjętym modelem, bez deklarowania osobnej tożsamości iCloud.

Zrzuty przed/po unieważnieniu, nowej rejestracji i przypisania roli zachowano prywatnie; raport dowodowy zawiera ich lokalne ścieżki i SHA. Nie dodano do Git zrzutów zawierających nazwę konta właściciela ani pełnego bieżącego inwentarza.

## Przebieg i wynik

Uruchomiono dokładnie CLI z przetestowanego commitu5432db8 na Node22.23.5, z prywatnym inwentarzem SHA256 `529f04556a612b06513b5418186345dd53b0fef3114ae416c20790d0622fbd26`. Przed aktywacją `inspect` potwierdził pusty stan dziennika. Permit związano z tym SHA, nowym keyID/SPKI, znanym starym ID/SPKI, Development/public oraz jednym oknem do30min. Nie było ponownej próby.

Silnik potwierdził kolejno:

1. Nieobecność wszystkich ośmiu dokładnych ID przed utworzeniem.
2. Jeden batch create i dokładny odczyt/porównanie początkowych pól oraz tagów wszystkich ośmiu typów.
3. Replace z bieżącymi tagami i odczyt potwierdzający minimalne bariery oraz usunięcie treści. Checkpoint testowy przeszedł na kolejny anchor.
4. Odrzucenie replace ze starymi tagami jako CONFLICT; payload zawierał już puste bariery, więc nie mógł przywrócić dawnej treści.
5. Ponowną identyfikację własnych rekordów, conditional delete po świeżych tagach i dokładny lookup potwierdzający NOT_FOUND dla wszystkich ośmiu.

Wynik: `protocol_verified`, exit0, protocolSucceeded/cleanupSucceeded/storageHealthy=true, callsTotal/windowCalls=9, brak errorCode/cleanupWarning, pendingRecordNames/skippedExistingRecordNames puste i pendingIO=false. Po wyjściu procesu ponownie otwarto SQLite bez sieci: phase=settled, protocolPassed/cleanupComplete=true i8wierszy confirmedCreated/status=absent. SHA pełnego prywatnego raportu: `30ec7731447822c5691e8ab910f79bc564c1de3c7ec054fd274ceeb29558419e`.

Proces zakończono, prywatny permit usunięto i zsynchronizowano katalog. Nowy klucz i rola pozostają zgodnie ze zgodą do dalszych uzgodnionych testów; nie aktywuje to bramki ani kolejnej próby. Historyczne kopie starego klucza nie zostały skasowane przez odwołanie rejestracji; nie mają już aktywnej rejestracji uwierzytelniania w tym środowisku.

## Granice odbioru

Użyto wyłącznie syntetycznego konta/pseudonimu/tekstu, stałego0,0 bez GPS, metadanych avatara bez obrazu/ASSET i osobnego losowego checkpointu. Nie dotykano prywatnych profili, rzeczywistego checkpointu gateway, innych danych użytkowników, Muzyki, Firebase lub Production. Nie utworzono usługi, nie przekazano sekretu Cloudflare, nie uruchomiono opłat ani TestFlight.

Nie zaliczono regionalnych query i indeksów, ASSET/upload/CDN/usuwania plików, rzeczywistego SIWA, odbierania uprawnień, testów dwóch zwykłych kont A/B, hostowanego Runtime/alarmu lub limitów Free. Te odbiory i pełny plan migracji pozostają wymagane. Zwykły punkt wejścia aplikacji nadal używa Firebase; tej próby nie przedstawiamy jako gotowego wydania.
