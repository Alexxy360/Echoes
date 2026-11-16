# Prywatny pseudonim w kontrolowanej aplikacji iOS

CK-04e.1, 16 listopada 2026. Kontrolowany Runtime łączy teraz istniejący PrivateProfileStore/NativePrivateProfileDatabase z onboardingiem i ustawieniami. Zwykły punkt wejścia pozostaje przy Firebase, aktywacja nowych usług jest wyłączona. Kod używa właściwego adaptera SDK, ale testy tego etapu modelują dostawców. Nie jest to potwierdzenie rzeczywistego zapisu w CloudKit.

## Dane i zgoda

Pseudonim trafia do EchoesPrivateProfileV1/profile.v1 we własnej strefie PrivateAccountScope, razem z atomowym guardem z CK-03b. Nie wprowadzono nowych pól ani avatarów do tego rekordu. Publiczny profil serwerowy i przyszłe zdjęcia pozostają osobne. Sam prywatny zapis nie włącza widoczności ani nie publikuje profilu/wiadomości.

Otwieranie mapy tworzy osobny Store powiązany z presentation UUID, pełnym snapshotem natywnego auth, UUID Echoes i iCloud. Odczyt wymaga jawnego authorizeRead: Runtime używa świeżej natywnej kontroli i /v1/auth/session przez istniejące authorizePrivateWrite; nie wywołuje okresowego resetu całego hosta. Przed/po tej kontroli musi nadal pasować ta sama prezentacja i scope. Store sprawdza je ponownie po powrocie SDK. NativePrivateProfileDatabase nadal wymaga świeżych kontroli przed zapisem i bezpośrednio przed dispatch.

Dawne UserDefaults userName/privacyAcceptedV2 oraz dane anonimowego Firebase nie są automatycznie przypisywane do konta Apple/iCloud. Nowa nazwa wymaga świadomego wpisania. Zapisany prywatny pseudonim jest odczytywany do pola po ponownym otwarciu. Akceptacja zasad w tym kontrolowanym etapie pozostaje na czas prezentacji; nie dodano trwałego rekordu zgody ani automatycznego wejścia na podstawie dawnej zgody Firebase.

## Wynik zapisu i konflikt

Aktywny pseudonim Core zmienia się dopiero po potwierdzeniu zapisu przez Store. Pierwsze wejście z nową nazwą także czeka na wynik. Jeżeli użytkownik wybiera tę samą, już odczytaną nazwę, wejście używa odczytanego profilu bez zbędnego ponownego zapisu. Przycisk Zapisz w ustawieniach zawsze dokonuje jawnego zapisu z aktualnym change tag.

Błąd po wysłaniu save/delete oznacza konieczność ponownego odczytu. Store nie ponawia mutacji i nie udaje pustej bazy. Użytkownik widzi edytowaną nazwę, osobno odczytany pseudonim i nazwę używaną w sesji. Odświeżenie nie nadpisuje szkicu ani nie zmienia automatycznie Core/publikowanej obecności. Po porównaniu użytkownik może wykonać nowy zapis. Konflikt nie korzysta z force overwrite. Nieznane pola rekordu i wcześniejsze zabezpieczenia guarda pozostają zachowane.

clearCache zmienia UUID operacji, usuwa busy i dane. Wynik starego load/save/delete oraz jego defer nie zastąpią nowego odczytu ani nie zwolnią jego busy, także w tym samym scope bez zmiany iCloud. Native invalidator czyści Store wraz z AppServices/CommunityDomain. Zwykłe close/reopen nie usuwa zdalnego profilu; konto usuwa istniejący przepływ z nowym potwierdzeniem Apple i biletem, nie przycisk lokalnej edycji.

## Odbiór lokalny i dalsze kroki

204/204 testy EchoesCloudKit (8 nowych), 22/22 UI (6 nowych), Debug ad-hoc Simulator i Release iOS bez podpisywania. Nowe testy obejmują świeżą autoryzację przed providerem, cancel, clear/reload tej samej przestrzeni, stare odczyty/zapisy/delete/defer, utracony ack i brak blind retry. UI sprawdza brak importu starego konta, odtworzenie przez nowy Store/prezentację, odczyt offline z jawnym retry, konflikt i unknown write, stary odczyt A po przejściu na B oraz AX XXXL. Syntetyczny transport używa modelowanej rewizji; nie potwierdza rzeczywistego CKRecord change tag.

[Raport i SHA](evidence/private-profile-ui-local-tests.json), [odtworzona nazwa](evidence/private-profile-restored.png), [konflikt](evidence/private-profile-conflict.png), [niepewny zapis po odczycie](evidence/private-profile-unknown.png), [nowe konto](evidence/private-profile-account.png), [odczyt po błędzie](evidence/private-profile-reload.png), [duży tekst](evidence/private-profile-large-text.png). PNG obejrzane bez edycji. Podgląd DEBUG używa rzeczywistego Store/klienta/Core, ale iCloud/API i baza są syntetyczne; nie wykonuje zapytań SDK do konta właściciela.

Następny krok to ograniczony test prawdziwego SDK Development: własne losowe strefy i nazwy, trwałość, konflikt, atomowy guard i sprzątanie, z zachowaniem istniejących zakresów zgód. Odrębnie potrzebne są realne SIWA/Workers, dwa zwykłe konta i osobna tożsamość serwisowa. [Plan zdjęć](PLAN_AVATAROW_CLOUDKIT.md) opisuje dalsze CKAsset, publikację/odczyt i usuwanie. Brak nowych uprawnień/kluczy, usług/sekretów, opłat, instalacji na telefonie oraz zmian Production/TestFlight i danych Firebase. Inwentarz urządzeń odczytano wyłącznie do przygotowania kolejnego kroku.
