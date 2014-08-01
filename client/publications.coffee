# Used for global variable assignments in local scopes
globals = @

catalogSettings =
  subscription: 'publications'
  documentClass: Publication
  variables:
    active: 'publicationsActive'
    ready: 'currentPublicationsReady'
    loading: 'currentPublicationsLoading'
    count: 'currentPublicationsCount'
    filter: 'currentPublicationsFilter'
    limit: 'currentPublicationsLimit'
    limitIncreasing: 'currentPublicationsLimitIncreasing'
    sort: 'currentPublicationsSort'
  signedInNoDocumentsMessage: "Import the first from the menu on top."
  signedOutNoDocumentsMessage: "Sign in and import the first."

Catalog.create catalogSettings

Template.publications.catalogSettings = ->
  catalogSettings

Template.publicationCatalogItem.events =
  'click .preview-link': (event, template) ->
    event.preventDefault()

    if template._publicationHandle
      # We ignore the click if handle is not yet ready
      $(template.findAll '.abstract').slideToggle('fast') if template._publicationHandle.ready()
    else
      template._publicationHandle = Meteor.subscribe 'publications-by-id', @_id, =>
        Deps.afterFlush =>
          $(template.findAll '.abstract').slideToggle('fast')

    return # Make sure CoffeeScript does not return anything

  'mousedown': (event, template) ->
    # Save mouse position so we can later detect selection actions in click handler
    template.data._previousMousePosition =
      pageX: event.pageX
      pageY: event.pageY

  'click': (event, template) ->
    # Don't redirect if user interacted with one of the actionable controls on the item
    return if $(event.target).closest('.actionable').length > 0

    # Don't redirect if this might have been a selection
    event.previousMousePosition = template.data._previousMousePosition
    return if event.previousMousePosition and (Math.abs(event.previousMousePosition.pageX - event.pageX) > 1 or Math.abs(event.previousMousePosition.pageY - event.pageY) > 1)

    # Redirect user to the publication
    Meteor.Router.toNew Meteor.Router.publicationPath template.data._id, template.data.slug

Template.publicationCatalogItem.created = ->
  @_publicationHandle = null

Template.publicationCatalogItem.rendered = ->
  $(@findAll '.scrubber').iscrubber
    direction: 'combined'

Template.publicationCatalogItem.destroyed = ->
  @_publicationHandle?.stop()
  @_publicationHandle = null

Template.publicationCatalogItem.documentLengthClass = ->
  switch
    when @numberOfPages < 10 then 'short'
    when @numberOfPages < 25 then 'medium'
    else 'long'

Template.publicationCatalogItem.annotationsCountDescription = ->
  Annotation.verboseNameWithCount @annotationsCount

Template.publicationCatalogItem.hasAbstract = ->
  @hasAbstract or @abstract

Template.publicationCatalogItem.open = Template.accessText.open
Template.publicationCatalogItem.closed = Template.accessText.closed
Template.publicationCatalogItem.private = Template.accessText.private

libraryMenuSubscriptionCounter = 0
libraryMenuSubscriptionPersonHandle = null
libraryMenuSubscriptionCollectionsHandle = null

onLibraryDropdownHidden = (event) ->
  # Return the library button to default state.
  $toolbar = $(this).parents('.toolbar')
  $toolbar.removeClass('displayed')
  $item = $toolbar.parents('.catalog-item')
  $item.removeClass('active').css('z-index','0')
  $button = $toolbar.find('.toolbar-button')
  $button.addClass('tooltip')

Template.publicationCatalogItemLibraryMenu.rendered = ->
  $(@findAll '.dropdown-anchor').off('dropdown-hidden').on('dropdown-hidden', onLibraryDropdownHidden)

Template.publicationCatalogItemLibraryMenu.events
  'click .toolbar-button': (event, template) ->

    $anchor = $(template.findAll '.dropdown-anchor')
    $anchor.toggle()

    if $anchor.is(':visible')
      # Because the dropdown is active, make sure toolbar doesn't disappear when not hovered
      $toolbar = $(template.firstNode).parents('.toolbar')
      $toolbar.addClass('displayed')

      # Also make sure the catalog item is on top of other items,
      # since the dropdown extends out of it
      $item = $toolbar.parents('.catalog-item')
      $item.addClass('active').css('z-index','10')

      # Temporarily remove and disable tooltips on the button
      $button = $(template.findAll '.toolbar-button')
      tooltipId = $button.attr('aria-describedby')
      $('#' + tooltipId).remove()
      $button.removeClass('tooltip')

    else
      onLibraryDropdownHidden.call($anchor, null)

    # We only subscribe to person's collections on click, because they are not immediately seen
    libraryMenuSubscriptionCollectionsHandle = Meteor.subscribe 'my-collections' unless libraryMenuSubscriptionCollectionsHandle

    return # Make sure CoffeeScript does not return anything

Template.publicationCatalogItemLibraryMenu.inLibrary = Template.publicationLibraryMenuButtons.inLibrary

Template.publicationCatalogItemLibraryMenu.created = ->
  libraryMenuSubscriptionCounter++
  # We need to subscribe to person's library here, because the icon of the menu changes to reflect in-library status
  libraryMenuSubscriptionPersonHandle = Meteor.subscribe 'my-person-library' unless libraryMenuSubscriptionPersonHandle

Template.publicationCatalogItemLibraryMenu.destroyed = ->
  libraryMenuSubscriptionCounter--

  unless libraryMenuSubscriptionCounter
    libraryMenuSubscriptionPersonHandle?.stop()
    libraryMenuSubscriptionPersonHandle = null
    libraryMenuSubscriptionCollectionsHandle?.stop()
    libraryMenuSubscriptionCollectionsHandle = null

Editable.template Template.publicationCatalogItemTitle, ->
  @data.hasMaintainerAccess Meteor.person @data.constructor.maintainerAccessPersonFields()
,
  (title) ->
    Meteor.call 'publication-set-title', @data._id, title, (error, count) ->
      return Notify.meteorError error, true if error
,
  "Enter publication title"

Template.publicationMetaMenuTitle[method] = Template.publicationCatalogItemTitle[method] for method in ['created', 'rendered', 'destroyed']

Template.publicationCatalogItemThumbnail.events
  'mouseenter li': (event, template) ->
    # Update page tooltip with current scrubbed over page
    $(template.firstNode).closest('.thumbnail').find('.ui-tooltip').text("Page #{@page} of #{@publication.numberOfPages}")

  'click li': (event, template) ->
    globals.startViewerOnPage = @page
    # TODO: Change when you are able to access parent context directly with Meteor
    publication = @publication
    Meteor.Router.toNew Meteor.Router.publicationPath publication._id, publication.slug
