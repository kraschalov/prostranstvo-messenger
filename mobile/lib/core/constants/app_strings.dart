class S {
  S._();

  static const appName = 'Пространство';

  // Общие
  static const continueLabel = 'Продолжить';
  static const cancel = 'Отмена';
  static const save = 'Сохранить';
  static const delete = 'Удалить';
  static const edit = 'Редактировать';
  static const send = 'Отправить';
  static const back = 'Назад';
  static const error = 'Ошибка';
  static const ok = 'Хорошо';
  static const create = 'Создать';
  static const loading = 'Загрузка…';
  static const retry = 'Повторить';
  static const close = 'Закрыть';
  static const copied = 'Скопировано';
  static const noInternet = 'Нет соединения с сервером';
  static const unknownError = 'Что-то пошло не так. Попробуйте ещё раз.';
  static const required = 'Обязательное поле';

  // Онбординг
  static const welcomeTitle = 'Добро пожаловать';
  static const welcomeSubtitle =
      'Федеративный защищённый мессенджер. Ваши сообщения шифруются на устройстве и не хранятся на серверах.';
  static const welcomeStart = 'Начать';
  static const serverTitle = 'Подключение к серверу';
  static const serverHint =
      'Например: mes.example.com или 192.168.1.10:5050 (в локальной сети HTTP)';
  static const serverName = 'Название сервера';
  static const serverNameHint = 'Например: Основной сервер';
  static const serverConnect = 'Подключиться';
  static const serverConnected = 'Сервер добавлен';
  static const inviteTitle = 'Код приглашения';
  static const inviteHint = 'Введите код, например ABCD-EFGH-1234-5678';
  static const inviteActivate = 'Активировать код';
  static const inviteInvalid = 'Неверный код приглашения';
  static const inviteUsed = 'Этот код уже использован';
  static const deviceBanned = 'Это устройство заблокировано администратором';
  static const profileSetupTitle = 'Ваш профиль';
  static const profileSetupSubtitle = 'Расскажите о себе — так другим проще вас найти.';
  static const nickname = 'Ник (логин)';
  static const nicknameHint = 'Например: sergei';
  static const displayName = 'Имя';
  static const gender = 'Пол';
  static const genderMale = 'Мужской';
  static const genderFemale = 'Женский';
  static const genderOther = 'Другое';
  static const birthDate = 'Дата рождения';
  static const age = 'Возраст';
  static const city = 'Город';
  static const goal = 'Цель знакомства';
  static const goalFriendship = 'Дружба';
  static const goalCommunication = 'Общение';
  static const goalRelations = 'Отношения';
  static const goalBusiness = 'Деловые знакомства';
  static const interests = 'Интересы (через запятую)';
  static const bio = 'О себе';
  static const bioHint = 'Несколько слов о себе…';
  static const addInterests = 'Добавить интерес';
  static const privacyTitle = 'Приватность';
  static const datingSwitch = 'Активировать межпространственность';
  static const datingSwitchDesc = 'Показывать вас в разделе «Инсайдеры»';
  static const federatedSearch = 'Разрешить поиск по серверу';
  static const federatedSearchDesc = 'Другие пользователи смогут находить вас по нику';
  static const crossServerMessages = 'Принимать сообщения с других серверов';
  static const crossServerMessagesDesc = 'Разрешить переписку с пользователями других серверов';
  static const skip = 'Пропустить';

  // Блокировка
  static const lockTitle = 'Приложение заблокировано';
  static const lockSetupTitle = 'Защита приложения';
  static const lockSetupSubtitle = 'Выберите способ разблокировки при запуске';
  static const lockBiometric = 'Биометрия';
  static const lockBiometricDesc = 'Отпечаток пальца или Face ID';
  static const lockPin = 'PIN-код (4 цифры)';
  static const lockPattern = 'Графический ключ';
  static const lockPassword = 'Пароль';
  static const lockEnterPin = 'Введите PIN-код';
  static const lockEnterPassword = 'Введите пароль';
  static const lockConfirm = 'Повторите для подтверждения';
  static const lockWrong = 'Неверно. Попробуйте снова';
  static const lockNotMatch = 'Коды не совпадают. Попробуйте снова';
  static const lockDrawPattern = 'Нарисуйте графический ключ';
  static const lockConfirmPattern = 'Нарисуйте ключ ещё раз';
  static const lockUseBiometric = 'Использовать биометрию';
  static const lockUseBiometricDesc = 'Быстрая разблокировка отпечатком пальца';
  static const biometricFailed =
      'Не удалось подтвердить биометрию. Попробуйте ещё раз или выберите PIN, графический ключ или пароль';
  static const lockSkip = 'Пропустить защиту';
  static const unlock = 'Разблокировать';
  static const lockForgotHint =
      'Забыли код? Очистите данные приложения (потребуется новый код приглашения)';

  // Дом
  static const chats = 'Чаты';
  static const contacts = 'Близкие';
  static const dating = 'Все';
  static const settings = 'Настройки';
  static const servers = 'Серверы';
  static const addServer = 'Добавить сервер';
  static const emptyChats = 'Пока нет чатов';
  static const emptyChatsHint = 'Найдите собеседника в «Близких» или «Все»';
  static const searchPlaceholder = 'Поиск';

  // Контакты (Mode A)
  static const contactSearchTitle = 'Поиск по нику';
  static const contactSearchHint = 'Введите @ник или ник@сервер';
  static const contactNotFound = 'Пользователь не найден';
  static const contactHidden = 'Пользователь скрыт из поиска';
  static const contactAdd = 'Добавить в контакты';
  static const contactAdded = 'Добавлено в контакты';
  static const contactWrite = 'Написать сообщение';

  // Знакомства (Mode B)
  static const datingTitle = 'Инсайдеры';
  static const datingEmptyBackground = 'Инсайдеры пространств';
  static const datingDisabledTitle = 'Режим инсайдеров выключен';
  static const datingDisabledHint =
      'Включите тумблер «Активировать межпространственность» в настройках профиля, чтобы видеть и быть видимыми.';
  static const datingFilters = 'Фильтры';
  static const datingAgeRange = 'Возраст';
  static const datingCity = 'Город';
  static const datingTags = 'Интересы';
  static const datingEmpty = 'Никого не нашлось';
  static const datingEmptyHint = 'Попробуйте изменить фильтры';
  static const datingLike = 'Нравится';
  static const datingSkipCard = 'Пропустить';

  // Чат
  static const chatEncrypted = 'Сообщения зашифрованы сквозным шифрованием (E2EE)';
  static const chatInputHint = 'Сообщение…';
  static const chatEditMark = 'изменено';
  static const chatDeleteForAll = 'Удалить для всех';
  static const chatDeleteForMe = 'Удалить у себя';
  static const chatScheduled = 'Отложить отправку';
  static const chatScheduleAt = 'Время отправки';
  static const chatMessageDeleted = 'Сообщение удалено';
  static const chatTyping = 'печатает…';
  static const chatSent = 'Отправлено';
  static const chatDelivered = 'Доставлено';
  static const chatRead = 'Прочитано';
  static const chatFailed = 'Не доставлено';
  static const chatCallAudio = 'Аудиозвонок';
  static const chatCallVideo = 'Видеозвонок';
  static const chatImage = 'Изображение';
  static const chatVoice = 'Голосовое сообщение';
  static const chatRecording = 'Запись…';
  static const chatRecordStop = 'Отправить';
  static const chatRecordCancel = 'Отменить';
  static const chatCallIncoming = 'Входящий вызов';

  // Настройки
  static const settingsProfile = 'Профиль';
  static const settingsSecurity = 'Безопасность';
  static const settingsLock = 'Защита приложения';
  static const settingsSpaces = 'Пространства';
  static const settingsPrivacy = 'Приватность и знакомства';
  static const settingsServers = 'Серверы и федерация';
  static const settingsLogout = 'Выйти из аккаунта';
  static const settingsLogoutConfirm = 'Выйти с этого устройства?';
  static const settingsAbout = 'О приложении';
  static const settingsVersion = 'Версия 0.1.0';
  static const settingsAdmin = 'Панель администратора';
  static const settingsBanned = 'Устройство заблокировано';
  static const settingsBannedHint = 'Ваше устройство заблокировано администратором сервера.';
  static const settingsAppealHint = 'Отправить сообщение Главному Администратору';
  static const settingsAppealSent = 'Обращение отправлено';
  static const settingsAppealRateLimit = 'Новое обращение можно отправить не раньше чем через 7 дней';

  // Пространства
  static const spacesTitle = 'Пространства';
  static const spacesCreate = 'Создать пространство';
  static const spacesName = 'Название пространства';
  static const spacesDescription = 'Описание';
  static const spacesCreated = 'Пространство создано';
  static const spacesInvite = 'Пригласить';
  static const spacesInviteRole = 'Роль приглашённого';
  static const spacesStandardRole = 'Пользователь';
  static const spacesFamilyRole = 'Член семьи';
  static const spacesInviteCode = 'Код приглашения';
  static const spacesInviteCodeHint = 'Покажите код тому, кого приглашаете';
  static const spacesNoRights = 'У вас нет прав создавать пространства';
  static const spacesEmpty = 'Пока нет пространств';
  static const spacesCopyCode = 'Скопировать код';
  static const spacesFamilyHint =
      'Члены семьи могут создавать до 3 своих пространств и приглашать пользователей. Приглашать других «членов семьи» нельзя.';

  // Серверы
  static const serverRemove = 'Удалить сервер';
  static const serverSwitch = 'Переключиться';
  static const serverLinkTitle = 'Связать сервер (S2S)';
  static const serverLinkHint = 'Домен удалённого сервера, например mes2.example.com';
  static const serverLink = 'Связать';
  static const serverLinked = 'Серверы связаны';
  static const serverPeers = 'Связанные серверы';
  static const serverEmptyPeers = 'Серверы ещё не связаны';
  static const serverFederationHint =
      'Связывание серверов позволяет находить пользователей и переписываться между серверами.';
}
