model parking_lot_simulation

global {
    int grid_width <- 5;   // Width of parking lot
    int grid_height <- 4;  // Height of parking lot
    int number_of_initial_cars <- grid_width * grid_height; // Initial parked cars
    float simulation_time <- 0.0; // Tracks simulation time in hours
    float cycle_duration <- 0.01; // Each cycle represents 0.01 hours (~36 seconds)
    int max_simulation_cycles <- int(24.0 / cycle_duration); // 24 hours worth of cycles
    int emergency_cars_per_hour <- rnd(1, 2); // 1-2 genuine emergency cars per hour
    int liar_cars_per_hour_min <- 1; // Minimum number of liars per hour (to be set by experiment)
    int liar_cars_per_hour_max <- 2; // Maximum number of liars per hour (to be set by experiment)
    int current_cycle <- 0;
    list<map> parking_events <- []; // Store parking events for analysis
    list<car> parked_emergency_cars <- []; // Track parked emergency cars for status switch
    list<car> cars_to_add_to_emergency <- []; // Temporary list to avoid concurrent modification

    // Constants
    float max_parking_duration <- 24.0;     // Maximum hours a car might stay
    int max_parking_history <- 10;         // Maximum number of previous visits to consider
    int liar_detection_threshold <- 3;     // Number of suspicious actions before flagging as liar
    float parking_rate <- 2.0;             // Cost per hour in arbitrary units
    float total_liar_cost <- 0.0;          // Total financial cost caused by liars
    float total_transferred_time_by_normal <- 0.0; // Total transferred time by normal cars
    int total_refusals <- 0;               // Track the number of individual refusals
    int total_cars_refused_for_parking <- 0; // Track the number of emergency cars refused parking
    list<string> refused_car_ids <- [];    // Track IDs of cars already counted as refused

    // Statistics for analysis
    int spots_to_genuine_emergencies <- 0;
    int spots_to_low_priority_liars <- 0;
    int spots_to_high_priority_liars <- 0;

    // Parameters for willingness distribution and liars (to be set by the experiment)
    float high_willingness_percentage <- 0.9; // Default to 90% high willingness
    bool include_liars <- true; // Default to including liars

    // Initialization
    init {
        create server number: 1;
        create car number: number_of_initial_cars with: [is_emergency::false, paid_duration::rnd(5.0, 10.0)];
    }

    // Time progression and emergency/liar car spawning
    reflex update_time {
        simulation_time <- simulation_time + cycle_duration;
        current_cycle <- current_cycle + 1;

        // Spawn 1-2 genuine emergency cars every hour
        if (current_cycle mod int(1.0 / cycle_duration) = 0) {
            int num_emergency <- rnd(1, 2);
            create car number: num_emergency with: [
                is_emergency::true,
                is_liar::false,
                is_parked::false,
                location::{grid_width * 10 + rnd(-2, 2), grid_height * 10 + rnd(-2, 2)},
                has_vacated_before::flip(0.5),
                paid_duration::0.0 // Emergency cars pay when they park
            ];

            // Spawn liar cars if include_liars is true
            if (include_liars) {
                int num_liars <- rnd(liar_cars_per_hour_min, liar_cars_per_hour_max);
                create car number: num_liars with: [
                    is_emergency::true, // Liars claim emergency status
                    is_liar::true,
                    liar_type::rnd(0, 1), // 0 = low-priority liar, 1 = high-priority liar
                    is_parked::false,
                    location::{grid_width * 10 + rnd(-2, 2), grid_height * 10 + rnd(-2, 2)},
                    has_vacated_before::flip(0.5),
                    paid_duration::rnd(5.0, 10.0) // Liars pre-pay like normal cars
                ];
            }
        }

        // Update parked_emergency_cars safely
        loop c over: cars_to_add_to_emergency {
            add c to: parked_emergency_cars;
        }
        cars_to_add_to_emergency <- [];

        // Stop simulation after 24 hours
        if (current_cycle >= max_simulation_cycles) {
            do pause;
            write "Simulation completed after 24 hours.";
            write "Analysis: Spots allocated to genuine emergencies: " + spots_to_genuine_emergencies;
            if (include_liars) {
                write "Analysis: Spots allocated to low-priority liars: " + spots_to_low_priority_liars;
                write "Analysis: Spots allocated to high-priority liars: " + spots_to_high_priority_liars;
                write "Analysis: Total financial cost caused by liars: " + total_liar_cost + " units.";
            }
            write "Analysis: Total transferred time by normal cars: " + total_transferred_time_by_normal + " hours.";
            write "Analysis: Total refusals by normal cars: " + total_refusals;
            write "Analysis: Total cars refused for parking: " + total_cars_refused_for_parking;
        }
    }
}

// Define the parking lot grid
grid parking_grid width: grid_width height: grid_height {
    int occupied <- 1; // 0 = free, 1 = occupied
    string car_id <- "";
    float remaining_paid_time <- 0.0; // Remaining paid time from previous occupant
}

// Server species for network management
species server skills: [network] {
    bool is_running <- false;

    init {
        try {
            do connect protocol: "tcp_server" port: 3001 with_name: "Server";
            is_running <- true;
            write "Server is running and waiting for connections...";
        } catch {
            write "Failed to start server: " + error;
            is_running <- false;
        }
    }

    reflex check_connections {
        if (!is_running) {
            write "Server is not running. Attempting to restart...";
            do connect protocol: "tcp_server" port: 3001 with_name: "Server";
            is_running <- true;
        }
    }
}

// Car species
species car skills: [network] {
    string id <- "Car_" + self.index;
    bool is_parked <- true;
    bool is_emergency <- false;
    bool is_liar <- false; // attribute to identify liars
    int liar_type <- 0; // 0 = low-priority liar, 1 = high-priority liar
    float willingness_to_help;
    string willingness_category <- "high"; // "high" or "low" willingness
    bool has_requested <- false; // Track if the car has sent a request in this cycle

    // Attributes
    float arrival_time;          // Time of arrival
    int parking_history <- 0;    // Number of previous parking instances
    int car_size <- rnd(1, 3);   // 1 = small, 2 = medium, 3 = large
    int priority_level <- 0;     // 0 = normal, 1-2 = emergency priority
    bool has_vacated_before <- false;
    parking_grid parking_spot <- nil;
    point location;
    float creation_time;
    bool is_connected <- false;

    // Liar detection attributes
    int emergency_request_count <- 0; // Track number of emergency requests made
    int suspicion_level <- 0; // Track suspicion of being a liar
    bool is_flagged_as_liar <- false; // Flag if detected as a liar

    // Payment attributes
    float paid_duration <- 0.0; // Hours paid for
    float transferred_time <- 0.0; // Time transferred from previous car

    // Calculate willingness to vacate
    action calculate_willingness(bool emergency_has_vacated_before, int emergency_priority_level) {
        float time_factor <- (simulation_time - arrival_time) / max_parking_duration;
        time_factor <- min([1.0, max([0.0, time_factor])]);

        float history_factor <- parking_history / float(max_parking_history);
        history_factor <- min([1.0, max([0.0, history_factor])]);

        float size_factor <- 0.4;
        if (car_size = 1) { size_factor <- 1.0; }
        else if (car_size = 2) { size_factor <- 0.7; }

        float priority_factor <- emergency_priority_level / 2.0; // Use emergency car's priority
        float vacated_before_bonus <- emergency_has_vacated_before ? 0.2 : 0.05;

        // Base willingness calculation
        float base_willingness <- 0.25 * time_factor + 0.15 * history_factor + 0.2 * size_factor +
                                  0.25 * priority_factor + 0.15 * vacated_before_bonus;
        base_willingness <- min([1.0, max([0.0, base_willingness])]);

        // Adjust willingness based on category
        if (willingness_category = "high") {
            // Ensure willingness is above 0.45 (range: 0.45 to 1.0)
            willingness_to_help <- 0.45 + (base_willingness * (1.0 - 0.45));
        } else {
            // Ensure willingness is below 0.45 (range: 0.0 to 0.45)
            willingness_to_help <- base_willingness * 0.45;
        }
    }

    init {
        arrival_time <- simulation_time;
        creation_time <- simulation_time;

        if (!is_emergency) {
            parking_history <- rnd(0, 5);
            priority_level <- 0;
            willingness_category <- flip(high_willingness_percentage) ? "high" : "low";
        } else {
            parking_history <- rnd(0, 3);
            if (is_liar) {
                // Liars set priority based on liar_type
                priority_level <- (liar_type = 0) ? 1 : 2; // Low-priority (1) or high-priority (2)
            } else {
                priority_level <- rnd(1, 2); // Genuine emergencies
            }
        }

        do calculate_willingness(false, 0);

        try {
            do connect to: "localhost" protocol: "tcp_client" port: 3001 with_name: id;
            is_connected <- true;
            write "Car " + id + " connected to the server.";
        } catch {
            write "Failed to connect " + id + ": " + error;
            is_connected <- false;
        }

        if (!is_emergency and parking_spot = nil) {
            int spot_index <- self.index;
            if (spot_index < (grid_width * grid_height)) {
                parking_spot <- parking_grid[spot_index];
                parking_spot.occupied <- 1;
                parking_spot.car_id <- id;
                location <- parking_spot.location;
            }
        }

        if (is_emergency and is_connected) {
            do request_parking;
        }
    }

    aspect default {
        draw circle(6) at: location color: is_emergency ? (is_liar ? #red : #orange) : #blue; // Liars in red, genuine emergencies in orange, normal in blue
    }

    reflex update_willingness when: is_parked and !is_emergency {
        do calculate_willingness(false, 0);
    }

    // Normal cars pay more if their paid time runs out
    reflex pay_more_if_overstayed when: !is_emergency and is_parked {
        float time_parked <- simulation_time - arrival_time;
        if (time_parked >= paid_duration) {
            float additional_time <- rnd(2.0, 5.0); // Pay for 2-5 more hours
            paid_duration <- paid_duration + additional_time;
            write "Car " + id + " overstayed its paid time (" + time_parked + " hours parked, " + paid_duration + " hours paid). Added " + additional_time + " more hours.";
        }
    }

    // Emergency car (or liar) requests parking
    action request_parking {
        if (is_connected) {
            emergency_request_count <- emergency_request_count + 1; // Increment request count
            write "Car " + id + " (is_liar: " + is_liar + ", liar_type: " + liar_type + ") is requesting a parking spot at " + simulation_time + " hours (has_vacated_before: " + has_vacated_before + ", priority_level: " + priority_level + ").";
            list<string> connected_cars <- (car where (!each.is_emergency and each.is_parked and each.is_connected)) collect (each.id);
            if (length(connected_cars) > 0) {
                write "Debug: Found " + length(connected_cars) + " parked cars: " + connected_cars;
            }
            loop car_id over: connected_cars {
                try {
                    do send to: car_id contents: ["EMERGENCY_REQUEST", has_vacated_before, priority_level];
                } catch {
                    write "Error sending from " + id + " to " + car_id + ": " + error;
                }
            }
            write "Car " + id + " sent request to " + length(connected_cars) + " cars.";
            has_requested <- true; // Mark that this car has made a request
        }
    }

    // Parked cars receive emergency requests
    reflex receive_message when: has_more_message() and is_parked and !is_emergency and is_connected {
        try {
            message mess <- fetch_message();
            if (mess.contents[0] = "EMERGENCY_REQUEST") {
                bool emergency_has_vacated <- mess.contents[1];
                int emergency_priority <- mess.contents[2];
                do calculate_willingness(emergency_has_vacated, emergency_priority);
                float time_parked <- simulation_time - arrival_time;
                write "Parked car " + id + " received emergency request from car with has_vacated_before: " + emergency_has_vacated + 
                      " and priority_level: " + emergency_priority + 
                      " (willingness: " + willingness_to_help + ", car_size: " + car_size + ", priority_level: " + priority_level + 
                      ", parking_history: " + parking_history + ", time_parked: " + time_parked + " hours).";
                if (willingness_to_help <= 0.45) {
                    write "Car " + id + " refuses to vacate for the emergency car (willingness: " + willingness_to_help + " is less than or equal to 0.45).";
                    total_refusals <- total_refusals + 1;
                }
                int num_waiting <- length(car where (each.is_emergency and !each.is_parked));
                int num_vacated <- length(parking_grid where (each.occupied = 0));
                if (num_waiting > num_vacated) {
                    list<car> willing_cars <- car where (!each.is_emergency and each.is_parked and each.is_connected and each.willingness_to_help > 0.45);
                    list<car> sorted_willing_cars <- willing_cars sort_by (-each.willingness_to_help);
                    int spots_to_vacate <- min([num_waiting - num_vacated, length(sorted_willing_cars)]);
                    loop i from: 0 to: min([length(sorted_willing_cars) - 1, spots_to_vacate - 1]) {
                        ask sorted_willing_cars[i] {
                            do vacate_spot;
                        }
                    }
                    // Check if no cars were willing to vacate
                    if (length(sorted_willing_cars) = 0) {
                        // Find the requesting cars that are still waiting
                        list<car> waiting_cars <- car where (each.is_emergency and !each.is_parked and each.has_requested);
                        loop waiting_car over: waiting_cars {
                            if (!(refused_car_ids contains waiting_car.id)) {
                                total_cars_refused_for_parking <- total_cars_refused_for_parking + 1;
                                add waiting_car.id to: refused_car_ids;
                                write "Car " + waiting_car.id + " was refused parking by all parked cars at " + simulation_time + " hours.";
                            }
                        }
                    }
                }
            }
        } catch {
            write "Error in parked car " + id + " receiving message: " + error;
        }
    }

    // Reset has_requested flag after the cycle
    reflex reset_request_flag when: is_emergency and !is_parked {
        has_requested <- false;
    }

    // Vacate a parking spot
    action vacate_spot {
        if (parking_spot != nil) {
            float time_parked <- simulation_time - arrival_time;
            float remaining_time <- max([0.0, paid_duration - time_parked]);
            parking_spot.remaining_paid_time <- remaining_time; // Transfer remaining paid time
            if (!is_emergency and remaining_time > 0.0) {
                total_transferred_time_by_normal <- total_transferred_time_by_normal + remaining_time;
                write "Normal car " + id + " transferred " + remaining_time + " hours to the next occupant.";
            }
            parking_spot.occupied <- 0;
            parking_spot.car_id <- "";
            add map("time"::simulation_time, "event"::id + " vacated spot", "spot"::parking_spot.location, "remaining_time"::remaining_time) to: parking_events;
            write "Car " + id + " vacated spot at " + simulation_time + " hours (time parked: " + time_parked + ", paid: " + paid_duration + ", remaining: " + remaining_time + " hours).";
            if (is_connected) {
                is_connected <- false;
            }
            do die;
        }
    }

    // Emergency car (or liar) checks for a parking spot
    reflex check_for_spot when: is_emergency and !is_parked and is_connected {
        try {
            parking_grid free_spot <- first(parking_grid where (each.occupied = 0));
            if (free_spot != nil) {
                location <- free_spot.location;
                free_spot.occupied <- 1;
                free_spot.car_id <- id;
                is_parked <- true;
                arrival_time <- simulation_time;
                parking_spot <- free_spot;
                transferred_time <- free_spot.remaining_paid_time; // Inherit remaining paid time
                if (transferred_time > 0.0) {
                    paid_duration <- transferred_time; // Emergency vehicle uses transferred time
                } else {
                    paid_duration <- rnd(5.0, 10.0); // Pay normally if no transferred time
                }
                free_spot.remaining_paid_time <- 0.0; // Reset after transfer
                add map("time"::simulation_time, "event"::id + " parked", "spot"::free_spot.location, "transferred_time"::transferred_time, "paid_duration"::paid_duration) to: parking_events;
                write "Car " + id + " (is_liar: " + is_liar + ") parked at " + simulation_time + " hours, transferred time: " + transferred_time + ", paid duration: " + paid_duration + " hours.";
                // Update statistics and track liar cost
                if (is_liar) {
                    if (liar_type = 0) {
                        spots_to_low_priority_liars <- spots_to_low_priority_liars + 1;
                    } else {
                        spots_to_high_priority_liars <- spots_to_high_priority_liars + 1;
                    }
                    if (transferred_time > 0.0) {
                        float liar_cost <- transferred_time * parking_rate; // Cost of transferred time not paid by liar
                        total_liar_cost <- total_liar_cost + liar_cost;
                        write "Liar " + id + " caused a financial discrepancy of " + liar_cost + " units by using " + transferred_time + " hours of transferred time.";
                    }
                } else {
                    spots_to_genuine_emergencies <- spots_to_genuine_emergencies + 1;
                }
                // Add to temporary list to avoid concurrent modification
                add self to: cars_to_add_to_emergency;
                // Remove from refused list since the car parked
                if (refused_car_ids contains id) {
                    remove id from: refused_car_ids;
                }
            } else if (simulation_time - creation_time > 0.1) {
                add map("time"::simulation_time, "event"::id + " left without parking", "spot"::"N/A") to: parking_events;
                write "Car " + id + " (is_liar: " + is_liar + ") left without parking at " + simulation_time + " hours.";
                if (is_connected) {
                    is_connected <- false;
                }
                do die;
            }
        } catch {
            write "Error in car " + id + " checking for spot: " + error;
        }
    }

    // Check connection status
    reflex check_connection when: !is_connected {
        try {
            do connect to: "localhost" protocol: "tcp_client" port: 3001 with_name: id;
            is_connected <- true;
            write "Car " + id + " reconnected to the server.";
        } catch {
            write "Car " + id + " failed to reconnect: " + error;
        }
    }

    // Switch genuine emergency car to normal car after 2 hours
    reflex switch_to_normal when: is_emergency and is_parked and !is_liar {
        float time_parked <- simulation_time - arrival_time;
        if (time_parked >= 2.0) {
            if (parking_spot = nil) {
                write "Warning: Car " + id + " has no parking spot despite being parked at " + simulation_time + " hours.";
                return;
            }
            write "Switching genuine emergency car " + id + " to normal car after " + time_parked + " hours at " + simulation_time + " hours.";
            is_emergency <- false;
            priority_level <- 0;
            remove self from: parked_emergency_cars;
            add map("time"::simulation_time, "event"::id + " switched to normal", "spot"::parking_spot.location) to: parking_events;
        }
    }

    // Liar detection mechanism
    reflex detect_liar when: is_emergency and include_liars {
        // Increment suspicion if car makes repeated emergency requests
        if (emergency_request_count > 1) {
            suspicion_level <- suspicion_level + 1;
            write "Car " + id + " (is_liar: " + is_liar + ") has made " + emergency_request_count + " emergency requests, increasing suspicion to " + suspicion_level + ".";
        }
        // Flag as liar if suspicion exceeds threshold
        if (suspicion_level >= liar_detection_threshold and !is_flagged_as_liar) {
            is_flagged_as_liar <- true;
            write "Car " + id + " (is_liar: " + is_liar + ") has been flagged as a potential liar at " + simulation_time + " hours.";
            // Apply penalty: reduce priority
            priority_level <- max([0, priority_level - 1]);
            write "Car " + id + " priority reduced to " + priority_level + " due to liar detection.";
        }
    }

    // Liars may leave quickly to avoid detection
    reflex liar_behavior when: is_liar and is_parked and include_liars {
        float time_parked <- simulation_time - arrival_time;
        if (time_parked >= 24 and flip(0.7)) { // Liars may leave after 24 hours with 70% chance
            write "Liar car " + id + " (liar_type: " + liar_type + ") is leaving after " + time_parked + " hours to avoid detection at " + simulation_time + " hours.";
            parking_spot.occupied <- 0;
            parking_spot.car_id <- "";
            add map("time"::simulation_time, "event"::id + " (liar) left", "spot"::parking_spot.location) to: parking_events;
            if (is_connected) {
                is_connected <- false;
            }
            do die;
        }
    }
     reflex strategic_lying when: is_liar and !is_flagged_as_liar and !is_parked {
    // Only lie (i.e., request emergency) if suspicion is low
    	if (suspicion_level < liar_detection_threshold - 1 and flip(0.6)) {
        	do request_parking;
    	} else {
        	write "Liar " + id + " is holding back to avoid detection (suspicion: " + suspicion_level + ").";
    	}
	}
}

// Experiments Without Liars

// Experiment for All Yes Scenario (100% Yes, No Liars)
experiment AllYesNoLiars type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 1.0;
    parameter "Include Liars" var: include_liars <- false;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}

// Experiment for High Yes Scenario (90% Yes, 10% No, No Liars)
experiment HighYesNoLiars type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 0.9;
    parameter "Include Liars" var: include_liars <- false;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}

// Experiment for High No Scenario (90% No, 10% Yes, No Liars)
experiment HighNoNoLiars type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 0.1;
    parameter "Include Liars" var: include_liars <- false;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}

// Experiment for 50% Yes Scenario (50% Yes, 50% No, No Liars)
experiment FiftyYesNoLiars type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 0.5;
    parameter "Include Liars" var: include_liars <- false;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}

// Experiments With Liars (0-1 Liars per Hour)

// Experiment for All Yes Scenario (100% Yes, 0-1 Liars)
experiment AllYesWithLiarsLow type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 1.0;
    parameter "Include Liars" var: include_liars <- true;
    parameter "Min Liars per Hour" var: liar_cars_per_hour_min <- 0;
    parameter "Max Liars per Hour" var: liar_cars_per_hour_max <- 1;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}

// Experiment for High Yes Scenario (90% Yes, 10% No, 0-1 Liars)
experiment HighYesWithLiarsLow type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 0.9;
    parameter "Include Liars" var: include_liars <- true;
    parameter "Min Liars per Hour" var: liar_cars_per_hour_min <- 0;
    parameter "Max Liars per Hour" var: liar_cars_per_hour_max <- 1;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}

// Experiment for High No Scenario (90% No, 10% Yes, 0-1 Liars)
experiment HighNoWithLiarsLow type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 0.1;
    parameter "Include Liars" var: include_liars <- true;
    parameter "Min Liars per Hour" var: liar_cars_per_hour_min <- 0;
    parameter "Max Liars per Hour" var: liar_cars_per_hour_max <- 1;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}

// Experiment for 50% Yes Scenario (50% Yes, 50% No, 0-1 Liars)
experiment FiftyYesWithLiarsLow type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 0.5;
    parameter "Include Liars" var: include_liars <- true;
    parameter "Min Liars per Hour" var: liar_cars_per_hour_min <- 0;
    parameter "Max Liars per Hour" var: liar_cars_per_hour_max <- 1;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}

// Experiments With Liars (1-2 Liars per Hour)

// Experiment for All Yes Scenario (100% Yes, 1-2 Liars)
experiment AllYesWithLiarsMedium type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 1.0;
    parameter "Include Liars" var: include_liars <- true;
    parameter "Min Liars per Hour" var: liar_cars_per_hour_min <- 1;
    parameter "Max Liars per Hour" var: liar_cars_per_hour_max <- 2;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}

// Experiment for High Yes Scenario (90% Yes, 10% No, 1-2 Liars)
experiment HighYesWithLiarsMedium type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 0.9;
    parameter "Include Liars" var: include_liars <- true;
    parameter "Min Liars per Hour" var: liar_cars_per_hour_min <- 1;
    parameter "Max Liars per Hour" var: liar_cars_per_hour_max <- 2;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}

// Experiment for High No Scenario (90% No, 10% Yes, 1-2 Liars)
experiment HighNoWithLiarsMedium type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 0.1;
    parameter "Include Liars" var: include_liars <- true;
    parameter "Min Liars per Hour" var: liar_cars_per_hour_min <- 1;
    parameter "Max Liars per Hour" var: liar_cars_per_hour_max <- 2;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}

// Experiment for 50% Yes Scenario (50% Yes, 50% No, 1-2 Liars)
experiment FiftyYesWithLiarsMedium type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 0.5;
    parameter "Include Liars" var: include_liars <- true;
    parameter "Min Liars per Hour" var: liar_cars_per_hour_min <- 1;
    parameter "Max Liars per Hour" var: liar_cars_per_hour_max <- 2;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}

// Experiments With Liars (4-5 Liars per Hour)

// Experiment for All Yes Scenario (100% Yes, 4-5 Liars)
experiment AllYesWithLiarsHigh type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 1.0;
    parameter "Include Liars" var: include_liars <- true;
    parameter "Min Liars per Hour" var: liar_cars_per_hour_min <- 4;
    parameter "Max Liars per Hour" var: liar_cars_per_hour_max <- 5;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}

// Experiment for High Yes Scenario (90% Yes, 10% No, 4-5 Liars)
experiment HighYesWithLiarsHigh type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 0.9;
    parameter "Include Liars" var: include_liars <- true;
    parameter "Min Liars per Hour" var: liar_cars_per_hour_min <- 4;
    parameter "Max Liars per Hour" var: liar_cars_per_hour_max <- 5;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}

// Experiment for High No Scenario (90% No, 10% Yes, 4-5 Liars)
experiment HighNoWithLiarsHigh type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 0.1;
    parameter "Include Liars" var: include_liars <- true;
    parameter "Min Liars per Hour" var: liar_cars_per_hour_min <- 4;
    parameter "Max Liars per Hour" var: liar_cars_per_hour_max <- 5;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}

// Experiment for 50% Yes Scenario (50% Yes, 50% No, 4-5 Liars)
experiment FiftyYesWithLiarsHigh type: gui {
    parameter "High Willingness Percentage" var: high_willingness_percentage <- 0.5;
    parameter "Include Liars" var: include_liars <- true;
    parameter "Min Liars per Hour" var: liar_cars_per_hour_min <- 4;
    parameter "Max Liars per Hour" var: liar_cars_per_hour_max <- 5;
    output {
        display "Parking Lot" type: java2D {
            grid parking_grid lines: #black;
            species car aspect: default;
        }
    }
}
