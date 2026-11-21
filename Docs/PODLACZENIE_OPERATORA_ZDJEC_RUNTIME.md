# Runtime operatora zgłoszonych zdjęć — CK-05d.2d.3b

Lokalna integracja panelu, hosta i odrębnego journala w GatewayDevelopmentRuntime. [Plan](PODLACZENIE_OPERATORA_ZDJEC_RUNTIME_PLAN.md) zapisano przed kodem. Usługi pozostają wyłączone, a zwykły adapter bez przełączenia.

## Otwarcie i lifetime

Runtime ma własny GatewayAvatarReportReviewJournal/Keychain/HTTP client/host. Słaby relay odcina host przy unieważnieniu community; callback trwałych zdarzeń trafia do istniejącego GatewayCommunityAvatarHost.observeModeration, osobno od uploadu. Nawigacja Development ma osobny route zgłoszeń zdjęć i warunek aktualnego rodzica. Oba panele zgłoszeń oraz panel uploadu zamykają poprzednią prezentację przed otwarciem.

openCommunity zamyka dawny domain i AppServices synchronicznie przed odczytem journali. GatewayCommunityBootstrap wykonuje kolejno dwa peek w dokładnym native/private/origin scope, sprawdzając cancellation, aktualny scope i nonce po każdym await oraz ponownie po getterze autoryzacji. Błąd dowolnego odczytu nie daje nowego bind. Slot pozostaje zajęty do powrotu zależności mimo invalidation/cancel. Nie ma nowych zapisów, rotacji lease, sieci ani przywracania obrazów w bootstrapie.

Root, relay, zmiana rodzica/tła/autoryzacji i usuwanie konta unieważniają oczekujące otwarcie. Po sprawdzeniu uchwytu Runtime przekazuje oba pending do bind zdjęć. W tym synchronicznym punkcie lifetime przejmuje nowy domain; zmiana root path na community nie unieważnia jego bieżącej autoryzacji. Jeśli rodzic znika między zwrotem async a nawigacją, discardCommunity zamyka wyłącznie dokładne nowo utworzone ID. Starsza odpowiedź nie zamyka nowszej prezentacji.

## Usuwanie danych

Host i bootstrap są unieważniane przed operacjami konta. Nowy journal otrzymuje fence binding/accountID, także dla nil-account binding, przed prepareForAccountDeletion. Dokładne owner erasure obejmuje jego namespace i wszystkie origin tego owner. Kod nie usuwa innych service lub owner. Niepewny błąd cleanup nadal kończy się błędem procesu usuwania zgodnie z istniejącym kontraktem.

## Rzeczywisty lokalny Keychain

AvatarReportReviewJournalStorageCheck używa trzech nowych losowych scope, dwóch losowych syntetycznych owners oraz dwóch origin. Syntetyczny JPEG przechodzi przez rzeczywisty parser ramki i ImageIO; hide_photo SavedIntent powstaje z publicznego API zweryfikowanego receipt, bez wewnętrznego konstruktora. Canned transport nie wykonuje URLSession, CloudKit, Firebase ani odczytu konta.

Sprawdzane są prepared/dispatched, ponowne otwarcie, nieostateczne notApplied, retiring i ponowne otwarcie, retired, terminalny ACK, WhenUnlockedThisDeviceOnly/noSync, odmowa4097B z zachowaniem oryginału, binding-wide fence bez accountID i owner erasure wszystkich własnych origin. Obcy syntetyczny owner pozostaje zapisany; końcowy cleanup i kontrola nieobecności dotyczą wyłącznie nowo wylosowanych zakresów.

Dedykowany wynik nowej kontroli jest sprawdzany przez UI. Zbiorcza kontrola propaguje jej błąd; dodatkowa odmowa oversized write sprawdza ten przepływ oraz cleanup na drodze błędu. DEBUG markery/fault/API nie występują w Release. To rzeczywisty Security w aplikacji Simulatora, a nie dowód fizycznego szyfrowania, rzeczywistego konta lub serwerowych uprawnień.

## Dowody i ograniczenia

Dokładne logi/SHA, przebiegi pakietu, UI i obejrzane zrzuty: [dowody](evidence/reported-photo-review-runtime-local-tests.json). Gotowy route z rzeczywistym zalogowanym kontem oraz cały Runtime z usługami nie były uruchamiane. Root testowany lokalnie w stanie bez aktywacji, panele na syntetycznych providerach, a bootstrap na modelowanych odczytach i prawdziwych journalach z pamięciowym storage.

Rzeczywiste SIWA, CloudKit query/ASSET/CDN i schemat EchoesAvatarReportV1, dwa zwykłe konta A/B, hosted Free/alarmy/limity i urządzenia pozostają wymagane. Bez nowych usług, aktywacji, praw, kluczy, sekretów, opłat, zmian Production, danych Firebase lub publikacji TestFlight. Zastana zmiana project.pbxproj pozostaje zachowana.
