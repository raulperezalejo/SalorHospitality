$(function(){
  update_resources('documentready');
  
  if (typeof(manage_counters_interval) == 'undefined') {
    manage_counters_interval = window.setInterval("manage_counters();", 1000);
  }
  
  if (!_get('customers.button_added')) {
    connect('customers_entry_hook','after.go_to.table',add_customers_button);
  }
  
  if (!_get('dmenucard.button_added')) {
    connect('dmenucard_entry_hook','after.go_to.table',add_dmenucard_button);
  }
})