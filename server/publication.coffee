crypto = Npm.require 'crypto'

typeIsArray = Array.isArray || ( value ) -> return {}.toString.call( value ) is '[object Array]'

class @Publication extends @Publication
  @MixinMeta (meta) =>
    meta.fields.slug.generator = (fields) ->
      if fields.title
        [fields._id, URLify2 fields.title]
      else
        [fields._id, '']
    meta

  checkCache: =>
    return if @cached

    if not Storage.exists @filename()
      console.log "Caching PDF for #{ @_id } from the central server"

      pdf = HTTP.get 'http://stage.peerlibrary.org' + @url(),
        timeout: 10000 # ms
        encoding: null # PDFs are binary data

      Storage.save @filename(), pdf.content

    @cached = true
    Publications.update @_id, $set: cached: @cached

    pdf?.content

  process: (pdf, initCallback, textCallback, pageImageCallback, progressCallback) =>
    pdf ?= Storage.open @filename()
    initCallback ?= (numberOfPages) ->
    textCallback ?= (pageNumber, x, y, width, height, direction, text) ->
    pageImageCallback ?= (pageNumber, canvasElement) ->
    progressCallback ?= (progress) ->

    console.log "Processing PDF for #{ @_id }: #{ @filename() }"

    PDF.process pdf, initCallback, textCallback, pageImageCallback, progressCallback

    @processed = true
    Publications.update @_id, $set: processed: @processed

  _temporaryFullFilename: =>
    assert @importing?.by?[0]?.person?._id
    assert.equal @importing.by[0].person._id, Meteor.personId()

    Publication._filenamePrefix() + 'tmp' + Storage._path.sep + @importing.by[0].temporary + '.pdf'

  _uploadOffsets: (personId) =>
    return _.map Meteor.settings.uploadKeys, (key) ->
      hmac = crypto.createHmac 'sha256', key
      hmac.update personId
      hmac.update @_id
      digest = hmac.digest 'hex'
      return parseInt(digest, 16)

  # A subset of public fields used for search results to optimize transmission to a client
  # This list is applied to PUBLIC_FIELDS to get a subset
  @PUBLIC_SEARCH_RESULTS_FIELDS: ->
    [
      'slug'
      'created'
      'updated'
      'authors'
      'title'
      'numberOfPages'
    ]

  # A set of fields which are public and can be published to the client
  @PUBLIC_FIELDS: ->
    fields:
      slug: 1
      created: 1
      updated: 1
      authors: 1
      title: 1
      numberOfPages: 1
      abstract: 1
      doi: 1
      foreignId: 1
      source: 1
      metadata: 1

Meteor.methods
  createPublication: (filename, sha256) ->
    throw new Meteor.Error 403, 'User is not signed in.' unless Meteor.personId()

    existingPublication = Publications.findOne
      sha256: sha256

    # Filter importing.by to contain only this person
    if existingPublication?.importing?.by
      existingPublication.importing.by = _.filter existingPublication.importing.by, (importingBy) ->
        return importingBy.person._id is Meteor.personId()

    if existingPublication?.importing?.by?[0]?
      # This person already has an import, so ask for confirmation or upload
      return [existingPublication._id, if existingPublication.cached then existingPublication._uploadOffsets Meteor.personId() else null]

    if existingPublication?.metadata
      # We already have the PDF, so ask for verification
      return [existingPublication._id, existingPublication._uploadOffsets Meteor.personId()]

    else if existingPublication?
      # We have the publication but no metadata, so get filename
      Publications.update
        _id: existingPublication._id
      ,
        $addToSet:
          'importing.by':
            person:
              _id: Meteor.personId()
            filename: filename
            temporary: Random.id()
            uploadProgress: 0
      # If we have the file, ask for verification. Otherwise, ask for upload
      return [existingPublication._id, if existingPublication.cached then existingPublication._uploadOffsets Meteor.personId() else null]

    else
      # We don't have anything, so create a new publication and ask for upload
      id = Publications.insert
        created: moment.utc().toDate()
        updated: moment.utc().toDate()
        source: 'upload'
        importing:
          by: [
            person:
              _id: Meteor.personId()
            filename: filename
            temporary: Random.id()
            uploadProgress: 0
          ]
        sha256: sha256
        cached: false
        metadata: false
        processed: false
      return [id, null]

  uploadPublication: (file) ->
    throw new Meteor.Error 401, 'User is not signed in.' unless Meteor.personId()
    throw new Meteor.Error 403, 'File is null.' unless file

    publication = Publications.findOne
      _id: file.name # file.options.publicationId
      'importing.by.person._id': Meteor.personId()
    ,
      fields:
        'importing.by.$': 1
        'sha256': 1
        'source': 1

    throw new Meteor.Error 403, 'No publication importing.' unless publication

    Storage.saveMeteorFile file, publication._temporaryFullFilename()

    Publications.update
      _id: publication._id
      'importing.by.person._id': Meteor.personId()
    ,
      $set:
        'importing.by.$.uploadProgress': file.end / file.size

    if file.end == file.size
      # TODO: Read and hash in chunks, when we will be processing PDFs as well in chunks
      pdf = Storage.open publication._temporaryFullFilename()

      hash = new Crypto.SHA256()
      hash.update pdf
      sha256 = hash.finalize()

      unless sha256 == publication.sha256
        throw new Meteor.Error 403, 'Hash does not match.'

      unless publication.cached
        # Upload is being finished for the first time, so move it to permanent location
        Storage.rename publication._temporaryFullFilename(), publication.filename()
        Publications.update
          _id: publication._id
        ,
          $set:
            cached: true

      # Hash was verified, so add it to uploader's library
      Persons.update
        '_id': Meteor.personId()
      ,
        $addToSet:
          library:
            _id: publication._id

  verifyPublication: (id, samples) ->
    throw new Meteor.Error 401, 'User is not signed in.' unless Meteor.personId()

    publication = Publications.findOne
      _id: id
      cached: true

    throw new Meteor.Error 403, 'No publication importing.' unless publication
    throw new Meteor.Error 403, 'Number of samples does not match.' unless (typeIsArray samples) and (samples.length == Meteor.settings.uploadKeys.length)

    buffer = Storage.open publication.filename()
    offsets = publication._uploadOffsets Meteor.personId(), bufferLength

    verified = _.every _.map offsets, (offset, key) ->
      clientSample = samples[key]
      serverSample = buffer.readDoubleBE offset % (buffer.length - 8)
      return clientSample == serverSample

    if verified
      # Samples were verified, so add it to person's library
      Persons.update
        '_id': Meteor.personId()
      ,
        $addToSet:
          library:
            _id: publication._id

      return true
    else
      return false


  confirmPublication: (id, metadata) ->
    throw new Meteor.Error 401, 'User is not signed in.' unless Meteor.personId()

    publication = Publications.findOne
      _id: id
      'importing.by.person._id': Meteor.personId()
      cached: true

    throw new Meteor.Error 403, 'No publication importing.' unless publication

    Publications.update
      _id: publication._id
    ,
      $set:
        _.extend _.pick(metadata or {}, 'authorsRaw', 'title', 'abstract', 'doi'),
          updated: moment.utc().toDate()
          metadata: true

Meteor.publish 'publications-by-author-slug', (slug) ->
  return unless slug

  author = Persons.findOne
    slug: slug

  return unless author

  Publications.find
    'authors._id': author._id
    cached: true
    processed: true
  ,
    Publication.PUBLIC_FIELDS()

Meteor.publish 'publications-by-id', (id) ->
  return unless id

  Publications.find
    _id: id
    cached: true
    processed: true
  ,
    Publication.PUBLIC_FIELDS()

Meteor.publish 'publications-by-ids', (ids) ->
  return unless ids?.length

  Publications.find
    _id:
      $in: ids
    cached: true
    processed: true
  ,
    Publication.PUBLIC_FIELDS()

Meteor.publish 'my-publications', ->
  # There are moments when two observes are observing mostly similar list
  # of publications ids so it could happen that one is changing or removing
  # publication just while the other one is adding, so we are making sure
  # using currentLibrary variable that we have a consistent view of the
  # publications we published
  currentLibrary = {}
  currentPersonId = null # Just for asserts
  handlePublications = null

  removePublications = (ids) =>
    for id of ids when currentLibrary[id]
      delete currentLibrary[id]
      @removed 'Publications', id

  publishPublications = (newLibrary) =>
    newLibrary ||= []

    added = {}
    added[id] = true for id in _.difference newLibrary, _.keys(currentLibrary)
    removed = {}
    removed[id] = true for id in _.difference _.keys(currentLibrary), newLibrary

    # Optimization, happens when a publication document is first deleted and
    # then removed from the library list in the person document
    if _.isEmpty(added) and _.isEmpty(removed)
      return

    oldHandlePublications = handlePublications
    handlePublications = Publications.find(
      _id:
        $in: newLibrary
      # TODO: Should be set as well if we have PDF locally
      # cached: true
      processed: true
    ,
      Publication.PUBLIC_FIELDS()
    ).observeChanges
      added: (id, fields) =>
        return if currentLibrary[id]
        currentLibrary[id] = true

        # We add only the newly added ones, others were added already before
        @added 'Publications', id, fields if added[id]

      changed: (id, fields) =>
        return if not currentLibrary[id]

        @changed 'Publications', id, fields

      removed: (id) =>
        return if not currentLibrary[id]
        delete currentLibrary[id]

        @removed 'Publications', id

    # We stop the handle after we established the new handle,
    # so that any possible changes hapenning in the meantime
    # were still processed by the old handle
    oldHandlePublications.stop() if oldHandlePublications

    # And then we remove those who are not in the library anymore
    removePublications removed

  handlePersons = Persons.find(
    'user._id': @userId
  ,
    fields:
      # id field is implicitly added
      'user._id': 1
      library: 1
  ).observeChanges
    added: (id, fields) =>
      # There should be only one person with the id at every given moment
      assert.equal currentPersonId, null
      assert.equal fields.user._id, @userId

      currentPersonId = id
      publishPublications _.pluck fields.library, '_id'

    changed: (id, fields) =>
      # Person should already be added
      assert.notEqual currentPersonId, null

      publishPublications _.pluck fields.library, '_id'

    removed: (id) =>
      # We cannot remove the person if we never added the person before
      assert.notEqual currentPersonId, null

      handlePublications.stop() if handlePublications
      handlePublications = null

      currentPersonId = null
      removePublications _.pluck currentLibrary, '_id'

  @ready()

  @onStop =>
    handlePersons.stop() if handlePersons
    handlePublications.stop() if handlePublications

Meteor.publish 'my-publications-importing', ->
  Publications.find
    'importing.by.person._id': @personId
  ,
    fields: _.extend Publication.PUBLIC_FIELDS().fields,
      cached: 1
      processed: 1
      'importing.by.$': 1
