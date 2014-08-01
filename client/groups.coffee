catalogSettings =
  subscription: 'groups'
  documentClass: Group
  variables:
    active: 'groupsActive'
    ready: 'currentGroupsReady'
    loading: 'currentGroupsLoading'
    count: 'currentGroupsCount'
    filter: 'currentGroupsFilter'
    limit: 'currentGroupsLimit'
    limitIncreasing: 'currentGroupsLimitIncreasing'
    sort: 'currentGroupsSort'
  signedInNoDocumentsMessage: "Create the first using the form on the right."
  signedOutNoDocumentsMessage: "Sign in and create the first."

Catalog.create catalogSettings

Template.groups.catalogSettings = ->
  catalogSettings

Deps.autorun ->
  if Session.equals 'groupsActive', true
    Meteor.subscribe 'my-groups'

Template.groups.events
  'submit .add-group': (event, template) ->
    event.preventDefault()

    name = $(template.findAll '.name').val().trim()
    return unless name

    Meteor.call 'create-group', name, (error, groupId) =>
      return Notify.meteorError error, true if error

      Notify.success "Group created."

    return # Make sure CoffeeScript does not return anything

Template.myGroups.myGroups = ->
  Group.documents.find
    _id:
      $in: _.pluck Meteor.person(inGroups: 1)?.inGroups, '_id'
  ,
    sort: [
      ['name', 'asc']
    ]

Editable.template Template.groupCatalogItemName, ->
  @data.hasMaintainerAccess Meteor.person @data.constructor.maintainerAccessPersonFields()
,
  (name) ->
    Meteor.call 'group-set-name', @data._id, name, (error, count) ->
      return Notify.meteorError error, true if error
,
  "Enter group name"
,
  true

Template.groupName[method] = Template.groupCatalogItemName[method] for method in ['created', 'rendered', 'destroyed']

Template.groupCatalogItem.events =
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

    # Redirect user to the group
    Meteor.Router.toNew Meteor.Router.groupPath template.data._id, template.data.slug

Template.groupCatalogItem.countDescription = ->
  if @membersCount is 1 then "1 member" else "#{ @membersCount } members"
