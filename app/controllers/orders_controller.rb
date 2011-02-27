class OrdersController < ApplicationController

  skip_before_filter :fetch_logged_in_user, :set_locale, :only => [:login]

  def index
    @tables = Table.all
    @categories = Category.find(:all, :order => :sort_order)
    @users = User.all
    session[:admin_interface] = !ipod? # admin panel per default on on workstation
    if MyGlobals::last_order_number.nil? # happens only at server restart
      MyGlobals::last_order_number = Order.last ? Order.last.nr : 0
    end
  end

  def login
    @current_user = User.find_by_login_and_password(params[:login], params[:password])
    if @current_user
      @tables = Table.all
      @categories = Category.find(:all, :order => :sort_order)
      session[:user_id] = @current_user
      session[:admin_interface] = !ipod? # admin panel per default on on workstation
      I18n.locale = @current_user.language
      render 'login_successful'
    else
      @users = User.all
      @errormessage = t :wrong_password
      render 'login_wrong'
    end
  end

  def logout
    session[:user_id] = @current_user = nil
    @users = User.all
    render 'go_to_login'
  end

  def show
    @client_data = File.exist?('config/client_data.yaml') ? YAML.load_file( 'config/client_data.yaml' ) : {}
    if params[:id] != 'last'
      @order = Order.find(params[:id])
    else
      @order = Order.find_all_by_finished(true).last
    end
    @previous_order, @next_order = neighbour_orders(@order)
    respond_to do |wants|
      wants.html
      wants.bon { render :text => generate_escpos_invoice(@order) }
    end
  end

  def unsettled
    @unsettled_orders = Order.find(:all, :conditions => { :settlement_id => nil, :finished => true })
    unsettled_userIDs = Array.new
    @unsettled_orders.each do |uo|
      unsettled_userIDs << uo.user_id
    end
    unsettled_userIDs.uniq!
    @unsettled_users = User.find(:all, :conditions => { :id => unsettled_userIDs })
    flash[:notice] = t(:there_are_no_open_settlements) if @unsettled_users.empty?
  end


  def separate_item
    @item=Item.find(params[:id])
    @separated_item = @item.clone
    @separated_item.count = 1
    @item.count -= 1
    @item.count == 0 ? @item.delete : @item.save
    @separated_item.save
    @order = @item.order
    @previous_order, @next_order = neighbour_orders(@order)
    respond_to do |wants|
      wants.js { render 'display_storno' }
    end
  end

  def toggle_admin_interface
    if session[:admin_interface]
      session[:admin_interface] = !session[:admin_interface]
    else
      session[:admin_interface] = true
    end
    @tables = Table.all
  end

  def print_and_finish
    @order = Order.find params[:id]
    if not @order.finished and ipod?
      @order.user = @current_user
      @order.created_at = Time.now
    end

    if @order.order # unlink any parent relationships
      @order.items.each do |item|
        item.item.update_attribute( :item_id, nil ) if item.item
        item.update_attribute( :item_id, nil )
      end
      @order.order.items.each do |item|
        item.item.update_attribute( :item_id, nil ) if item.item
        item.update_attribute( :item_id, nil )
      end
      @order.order.update_attribute( :order_id, nil )
      @order.update_attribute( :order_id, nil )
    end

    File.open('tmp/order.escpos', 'w') { |f| f.write(generate_escpos_invoice(@order)) }
    `cat tmp/order.escpos > /dev/ttyPS#{ params[:port] }`

    justfinished = false
    if not @order.finished
      @order.finished = true
      @order.printed_from = "#{ request.remote_ip } on printer #{ params[:port] }"
      justfinished = true
      @order.save
    end

    @orders = Order.find(:all, :conditions => { :table_id => @order.table, :finished => false })
    @order.table.update_attribute :user, nil if @orders.empty?
    @cost_centers = CostCenter.find_all_by_active(true)

    respond_to do |wants|
      wants.html { redirect_to order_path @order }
      wants.js {
        if not justfinished
          render :nothing => true
        elsif not @orders.empty?
          render('go_to_invoice_form')
        else
          @tables = Table.all
          render('go_to_tables')
        end
      }
    end
  end

  def go_to_order_form # to be called only with /id
    @order = Order.find(params[:id])
    @table = @order.table
    @cost_centers = CostCenter.find_all_by_active(true)
    render 'go_to_order_form'
  end

  def receive_order_attributes_ajax
    @cost_centers = CostCenter.find_all_by_active(true)
    MyGlobals::credits_left = Order.last ? Order.last.credit : YAML.load_file('config/initial_credits.yaml')['initial_credits']
    if not params[:order_action] == 'cancel_and_go_to_tables'
      if params[:order][:id] == 'add_offline_items_to_order'
        @order = Order.find(:all, :conditions => { :finished => false, :table_id => params[:order][:table_id] }).first
      else
        @order = Order.find(params[:order][:id]) if not params[:order][:id].empty?
      end

      if @order
        #similar to update
        @order.update_attributes(params[:order])
        @order.table.update_attribute :user, @order.user
      else
        #similar to create
        # create new order OR (if order exists already on table) add items to existing order
        @order = Order.new(params[:order])
        @order.nr = get_next_unique_and_reused_order_number
        @order.credit = MyGlobals::credits_left -= 1
        @order.sum = calculate_order_sum @order
        @order.cost_center = @cost_centers.first
        @order.save
        @order.table.update_attribute :user, @order.user
      end
      process_order(@order)
    end
    conditional_redirect_ajax(@order)
  end

  def storno
    @order = Order.find(params[:id])
    @previous_order, @next_order = neighbour_orders(@order)
    @order.update_attributes(params[:order])
    items_for_storno = Item.find(:all, :conditions => { :order_id => @order.id, :storno_status => 1 })
    make_storno(@order, items_for_storno)
    @order = Order.find(params[:id]) # re-read
    respond_to do |wants|
      wants.html
      wants.js { render 'display_storno' }
    end
  end

  def last_invoices
    @last_orders = Order.find(:all, :conditions => { :finished => true }, :limit => 10, :order => 'created_at DESC')
  end


  private

    def process_order(order)
      order.reload
      if order.items.size.zero?
        MyGlobals::unused_order_numbers << order.nr
        order.delete
        order.table.update_attribute :user, nil
        return
      end 

      order.update_attribute( :sum, calculate_order_sum(order) )

      File.open('bar.escpos', 'w') { |f| f.write(generate_escpos_items(order, :drink)) }
      File.open('kitchen.escpos', 'w') { |f| f.write(generate_escpos_items(order, :food)) }
      File.open('kitchen-takeaway.escpos', 'w') { |f| f.write(generate_escpos_items(order, :takeaway)) }

      group_identical_items(order)

      `cat bar.escpos > /dev/ttyPS1` #1 = Bar
      `cat kitchen.escpos > /dev/ttyPS0` #0 = Kitchen
      `cat kitchen-takeaway.escpos > /dev/ttyPS0` #0 = Kitchen
    end

    def conditional_redirect_ajax(order)
      @tables = Table.all

      render('go_to_tables') and return if not order or order.destroyed?

      case params[:order_action]
        when 'save_and_go_to_tables'
          render 'go_to_tables'
        when 'cancel_and_go_to_tables'
          render 'go_to_tables'
        when 'save_and_go_to_invoice'
          @orders = Order.find(:all, :conditions => { :table_id => order.table.id, :finished => false })
          render 'go_to_invoice_form'
        when 'move_order_to_table'
          move_order_to_table(order, params[:target_table])
          @tables = Table.all
          render 'go_to_tables'
      end
    end

    def move_order_to_table(order,target_table_id)
      @target_order = Order.find(:all, :conditions => { :table_id => target_table_id, :finished => false }).first
      if @target_order
        # mix items into existing order
        order.items.each do |i|
          i.update_attribute :order, @target_order
        end
        group_identical_items(@target_order)
        order.destroy
      else
        # move order to empty table
        order.update_attribute :table_id, target_table_id
      end

      # change table users and colors
      unfinished_orders_on_this_table = Order.find(:all, :conditions => { :table_id => order.table.id, :finished => false })
      order.table.update_attribute :user, nil if unfinished_orders_on_this_table.empty?
      unfinished_orders_on_target_table = Order.find(:all, :conditions => { :table_id => target_table_id, :finished => false })
      Table.find(target_table_id).update_attribute :user, order.user
    end

    def group_identical_items(o)
      items = o.items
      n = items.size - 1
      0.upto(n) do |i|
        (i+1).upto(n) do |j|
          if (items[i].article_id  == items[j].article_id and
              items[i].quantity_id == items[j].quantity_id and
              items[i].price       == items[j].price and
              items[i].comment     == items[j].comment
             )
            items[i].count += items[j].count and items[j].delete
            items[i].save
          end
        end         
      end
    end

    def neighbour_orders(order)
      orders = Order.find_all_by_finished(true)
      idx = orders.index(order)
      previous_order = orders[idx-1]
      previous_order = order if previous_order.nil?
      next_order = orders[idx+1]
      next_order = order if next_order.nil?
      return previous_order, next_order
    end

    def reduce_stocks(order)
      order.items.each do |item|
        item.article.ingredients.each do |ingredient|
          ingredient.stock.balance -= item.count * ingredient.amount
          ingredient.stock.save
        end
      end
    end



    
    # storno_status: 1 = marked for storno, 2 = is storno clone, 3 = storno original
    #
    def make_storno(order, items_for_storno)
      return if items_for_storno.empty?
      items_for_storno.each do |item|
        next if item.storno_status == 3 # only one storno allowed per item
        storno_item = item.clone
        storno_item.save
        storno_item.update_attribute :storno_status, 2 # tis is a storno clone
        item.update_attribute :storno_status, 3 # this is a storno original
      end
    end
end
